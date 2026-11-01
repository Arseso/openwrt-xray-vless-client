//! The router package from the latest GitHub release: luci-app-xvpn and its translations
//! (luci-i18n-xvpn-<lang>) are downloaded by the PC, not by the router, which needs no
//! access to GitHub. The web view picks the assets (src/core/routerpkg.ts) and uploads
//! them through ubus; here only the release, the download and its checks.
//!
//! pkg_latest asks the GitHub API for the latest release (anonymous: the repository is
//! public) and keeps its ipk assets; pkg_download gets one of those by name only, so the
//! web view never hands over a URL. An asset is taken only with a sha256 digest from the
//! API (GitHub computes it on upload) and only if the bytes match it; its size is limited.

use std::sync::Mutex;
use std::time::Duration;

use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tauri::ipc::Invoke;
use tauri::{App, Manager, State, Wry};

use crate::error::{Result, TransportError};

const REPO: &str = "Arseso/openwrt-xray-vless-client";
/// an ipk of luci-app-xvpn is ~100 KB, a translation a few KB
pub const MAX_SIZE: u64 = 4 << 20;
const API_TIMEOUT: Duration = Duration::from_secs(20);
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(60);

fn api_url() -> String {
    format!("https://api.github.com/repos/{REPO}/releases/latest")
}

/// where the assets of the release may come from (the API gives these URLs; GitHub
/// redirects them to its storage)
fn download_prefix() -> String {
    format!("https://github.com/{REPO}/releases/download/")
}

/// the release as the GitHub API gives it, only what is used
#[derive(Debug, Deserialize)]
struct ApiRelease {
    tag_name: String,
    #[serde(default)]
    html_url: String,
    #[serde(default)]
    assets: Vec<ApiAsset>,
}

#[derive(Debug, Deserialize)]
struct ApiAsset {
    name: String,
    size: u64,
    browser_download_url: String,
    /// "sha256:<hex>"; older assets have none (null)
    #[serde(default)]
    digest: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Asset {
    pub name: String,
    pub size: u64,
    pub url: String,
    /// lowercase hex
    pub sha256: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    pub tag: String,
    pub url: String,
    pub assets: Vec<Asset>,
}

/// what the web view sees: names and sizes, no URLs
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseInfo {
    pub tag: String,
    pub url: String,
    pub assets: Vec<AssetInfo>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AssetInfo {
    pub name: String,
    pub size: u64,
    /// false: the API gave no sha256 for it, it is not downloaded
    pub verified: bool,
}

/// the ipk files of the router package: luci-app-xvpn_*.ipk, luci-i18n-xvpn-*.ipk
pub fn is_package(name: &str) -> bool {
    let ok = name.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.~+".contains(&b));
    ok && name.ends_with(".ipk") && (name.starts_with("luci-app-xvpn_") || name.starts_with("luci-i18n-xvpn-"))
}

fn digest(d: Option<&str>) -> Option<String> {
    let hex = d?.strip_prefix("sha256:")?;
    (hex.len() == 64 && hex.bytes().all(|b| b.is_ascii_hexdigit())).then(|| hex.to_ascii_lowercase())
}

/// the answer of /releases/latest: its ipk assets from the expected place
pub fn parse_release(body: &[u8], prefix: &str) -> Result<Release> {
    let r: ApiRelease = serde_json::from_slice(body)
        .map_err(|e| TransportError::new("release_bad", format!("GitHub API: {e}")))?;
    let assets = r.assets.into_iter()
        .filter(|a| is_package(&a.name) && a.browser_download_url.starts_with(prefix))
        .map(|a| Asset { sha256: digest(a.digest.as_deref()), name: a.name, size: a.size, url: a.browser_download_url })
        .collect();
    Ok(Release { tag: r.tag_name, url: r.html_url, assets })
}

pub fn check_sha256(data: &[u8], expected: &str) -> Result<()> {
    let got: String = Sha256::digest(data).iter().map(|b| format!("{b:02x}")).collect();
    if got == expected {
        Ok(())
    } else {
        Err(TransportError::new("release_digest", format!("sha256 {got}, the release says {expected}")))
    }
}

fn client() -> Result<reqwest::Client> {
    let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
    let tls = rustls::ClientConfig::builder_with_provider(std::sync::Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .map_err(|e| TransportError::new("release_unreachable", e.to_string()))?
        .with_root_certificates(roots)
        .with_no_client_auth();
    // the GitHub API refuses requests without a User-Agent
    reqwest::Client::builder()
        .use_preconfigured_tls(tls)
        .user_agent(concat!("xvpn-desktop/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| TransportError::new("release_unreachable", e.to_string()))
}

fn net_error(what: &str, e: reqwest::Error) -> TransportError {
    TransportError::new("release_unreachable", format!("{what}: {e}"))
}

fn status_error(what: &str, r: &reqwest::Response) -> TransportError {
    let s = r.status();
    // anonymous API calls: 60 an hour per IP, then 403 (or 429) with x-ratelimit-remaining 0
    let limited = s.as_u16() == 429
        || (s.as_u16() == 403 && r.headers().get("x-ratelimit-remaining").is_some_and(|v| v == "0"));
    let mut e = TransportError::new(if limited { "release_rate_limit" } else { "release_http" }, format!("{what}: HTTP {s}"));
    e.status = Some(s.as_u16());
    e
}

pub async fn fetch_release(http: &reqwest::Client, url: &str, prefix: &str) -> Result<Release> {
    let r = http.get(url)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .timeout(API_TIMEOUT)
        .send().await.map_err(|e| net_error("GitHub API", e))?;
    if !r.status().is_success() {
        return Err(status_error("GitHub API", &r));
    }
    let body = read_limited(r, 1 << 20, "GitHub API").await?;
    parse_release(&body, prefix)
}

async fn read_limited(mut r: reqwest::Response, limit: u64, what: &str) -> Result<Vec<u8>> {
    let mut body = Vec::new();
    while let Some(chunk) = r.chunk().await.map_err(|e| net_error(what, e))? {
        if body.len() as u64 + chunk.len() as u64 > limit {
            return Err(TransportError::new("release_too_big", format!("{what}: more than {limit} bytes")));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// the bytes of one asset, checked against its size and sha256
pub async fn download(http: &reqwest::Client, a: &Asset) -> Result<Vec<u8>> {
    let Some(sha) = &a.sha256 else {
        return Err(TransportError::new("release_no_digest", format!("{}: the release gives no sha256", a.name)));
    };
    if a.size > MAX_SIZE {
        return Err(TransportError::new("release_too_big", format!("{}: {} bytes", a.name, a.size)));
    }
    let r = http.get(&a.url).timeout(DOWNLOAD_TIMEOUT).send().await.map_err(|e| net_error(&a.name, e))?;
    if !r.status().is_success() {
        return Err(status_error(&a.name, &r));
    }
    let data = read_limited(r, a.size, &a.name).await?;
    check_sha256(&data, sha)?;
    Ok(data)
}

/// the release of the last pkg_latest
#[derive(Default)]
struct Latest(Mutex<Option<Release>>);

pub fn init(app: &mut App) -> tauri::Result<()> {
    app.manage(Latest::default());
    Ok(())
}

/// commands named pkg_*; lib.rs routes them here
pub fn handler() -> impl Fn(Invoke<Wry>) -> bool + Send + Sync + 'static {
    tauri::generate_handler![pkg_latest, pkg_download]
}

#[tauri::command]
async fn pkg_latest(latest: State<'_, Latest>) -> Result<ReleaseInfo> {
    let r = fetch_release(&client()?, &api_url(), &download_prefix()).await?;
    let info = ReleaseInfo {
        tag: r.tag.clone(),
        url: r.url.clone(),
        assets: r.assets.iter().map(|a| AssetInfo { name: a.name.clone(), size: a.size, verified: a.sha256.is_some() }).collect(),
    };
    *latest.0.lock().unwrap() = Some(r);
    Ok(info)
}

/// one asset of the release pkg_latest found, base64 (the web view writes it to the
/// router with ubus file write, which takes base64)
#[tauri::command]
async fn pkg_download(latest: State<'_, Latest>, name: String) -> Result<String> {
    let asset = latest.0.lock().unwrap().as_ref().and_then(|r| r.assets.iter().find(|a| a.name == name).cloned());
    let Some(asset) = asset else {
        return Err(TransportError::new("release_no_asset", format!("{name}: not in the release")));
    };
    let data = download(&client()?, &asset).await?;
    Ok(base64::engine::general_purpose::STANDARD.encode(data))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const SHA_ABC: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    fn api_answer(prefix: &str) -> String {
        serde_json::json!({
            "tag_name": "v0.3.0",
            "html_url": "https://github.com/Arseso/openwrt-xray-vless-client/releases/tag/v0.3.0",
            "assets": [
                { "name": "luci-app-xvpn_0.3.0-r1_all.ipk", "size": 3, "digest": format!("sha256:{}", SHA_ABC.to_uppercase()),
                  "browser_download_url": format!("{prefix}v0.3.0/luci-app-xvpn_0.3.0-r1_all.ipk") },
                { "name": "luci-i18n-xvpn-ru_0.3.0-r1_all.ipk", "size": 3, "digest": null,
                  "browser_download_url": format!("{prefix}v0.3.0/luci-i18n-xvpn-ru_0.3.0-r1_all.ipk") },
                { "name": "luci-i18n-xvpn-de_0.3.0-r1_all.ipk", "size": 3, "digest": "md5:abc",
                  "browser_download_url": format!("{prefix}v0.3.0/luci-i18n-xvpn-de_0.3.0-r1_all.ipk") },
                { "name": "xvpn_0.3.0_amd64.AppImage", "size": 9, "digest": format!("sha256:{SHA_ABC}"),
                  "browser_download_url": format!("{prefix}v0.3.0/xvpn_0.3.0_amd64.AppImage") },
                { "name": "luci-app-xvpn_0.3.0-r1_all.ipk.evil", "size": 3, "digest": format!("sha256:{SHA_ABC}"),
                  "browser_download_url": "https://example.com/x.ipk" },
                { "name": "luci-app-xvpn_0.3.0-r2_all.ipk", "size": 3, "digest": format!("sha256:{SHA_ABC}"),
                  "browser_download_url": "https://example.com/luci-app-xvpn_0.3.0-r2_all.ipk" }
            ]
        }).to_string()
    }

    #[test]
    fn release_answer() {
        let p = "https://github.com/Arseso/openwrt-xray-vless-client/releases/download/";
        let r = parse_release(api_answer(p).as_bytes(), p).unwrap();
        assert_eq!(r.tag, "v0.3.0");
        let names: Vec<_> = r.assets.iter().map(|a| a.name.as_str()).collect();
        // not an ipk of the package, or from elsewhere: left out
        assert_eq!(names, ["luci-app-xvpn_0.3.0-r1_all.ipk", "luci-i18n-xvpn-ru_0.3.0-r1_all.ipk", "luci-i18n-xvpn-de_0.3.0-r1_all.ipk"]);
        assert_eq!(r.assets[0].sha256.as_deref(), Some(SHA_ABC));
        assert_eq!(r.assets[1].sha256, None);
        assert_eq!(r.assets[2].sha256, None);
        assert_eq!(parse_release(b"<html>", p).unwrap_err().kind, "release_bad");
        assert_eq!(parse_release(br#"{"tag_name":"v1"}"#, p).unwrap().assets, []);
    }

    #[test]
    fn package_names() {
        assert!(is_package("luci-app-xvpn_0.2.0-r1_all.ipk"));
        assert!(is_package("luci-i18n-xvpn-pt-br_0.2.0-r1_all.ipk"));
        assert!(!is_package("luci-app-xvpn-remote.json"));
        assert!(!is_package("luci-app-xvpn_../../x.ipk"));
        assert!(!is_package("luci-app-xvpn_0.2.0 r1.ipk"));
    }

    #[test]
    fn sha256() {
        assert!(check_sha256(b"abc", SHA_ABC).is_ok());
        let e = check_sha256(b"abd", SHA_ABC).unwrap_err();
        assert_eq!(e.kind, "release_digest");
    }

    /// a local HTTP server answering each connection with the next of `answers`
    async fn serve(answers: Vec<Vec<u8>>) -> String {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/", l.local_addr().unwrap());
        tokio::spawn(async move {
            for a in answers {
                let (mut s, _) = l.accept().await.unwrap();
                let mut buf = [0u8; 4096];
                let _ = s.read(&mut buf).await;
                let _ = s.write_all(&a).await;
                let _ = s.shutdown().await;
            }
        });
        url
    }

    fn http(status: &str, headers: &str, body: &[u8]) -> Vec<u8> {
        let mut v = format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n", body.len()).into_bytes();
        v.extend_from_slice(body);
        v
    }

    fn plain() -> reqwest::Client {
        reqwest::Client::builder().build().unwrap()
    }

    #[tokio::test]
    async fn release_and_download_over_http() {
        // the release first, then the asset
        let prefix = "http://127.0.0.1/";
        let api = serve(vec![http("200 OK", "", api_answer(prefix).as_bytes())]).await;
        let r = fetch_release(&plain(), &api, prefix).await.unwrap();
        assert_eq!(r.assets.len(), 3);

        let file = serve(vec![http("200 OK", "", b"abc"), http("200 OK", "", b"abd"), http("200 OK", "", b"abcd")]).await;
        let mut a = r.assets[0].clone();
        a.url = file;
        assert_eq!(download(&plain(), &a).await.unwrap(), b"abc");
        assert_eq!(download(&plain(), &a).await.unwrap_err().kind, "release_digest");
        // more than the API said
        assert_eq!(download(&plain(), &a).await.unwrap_err().kind, "release_too_big");

        let mut nodigest = r.assets[1].clone();
        nodigest.url = "http://127.0.0.1:1/".into();
        assert_eq!(download(&plain(), &nodigest).await.unwrap_err().kind, "release_no_digest");
        a.size = MAX_SIZE + 1;
        assert_eq!(download(&plain(), &a).await.unwrap_err().kind, "release_too_big");
    }

    #[tokio::test]
    async fn api_errors() {
        let api = serve(vec![
            http("403 Forbidden", "x-ratelimit-remaining: 0\r\n", b"{}"),
            http("404 Not Found", "", b"{}"),
        ]).await;
        let e = fetch_release(&plain(), &api, "").await.unwrap_err();
        assert_eq!(e.kind, "release_rate_limit");
        let e = fetch_release(&plain(), &api, "").await.unwrap_err();
        assert_eq!((e.kind, e.status), ("release_http", Some(404)));
        let e = fetch_release(&plain(), "http://127.0.0.1:1/", "").await.unwrap_err();
        assert_eq!(e.kind, "release_unreachable");
    }
}
