//! The router package from the latest GitHub release: luci-app-xvpn and its translations
//! (luci-i18n-xvpn-<lang>) are downloaded by the PC, not by the router, which needs no
//! access to GitHub. The web view picks the assets (src/core/routerpkg.ts) and uploads
//! them through ubus; here only the release, the download and its checks.
//!
//! pkg_latest asks the GitHub API for the latest release (anonymous: the repository is
//! public) and keeps its ipk assets; pkg_download gets one of those by name only, so the
//! web view never hands over a URL.
//!
//! What may be installed is decided by a signature, not by GitHub alone: `scripts/ci.sh
//! release` puts SHA256SUMS of the ipk files and SHA256SUMS.sig into the release, signed
//! (desktop/docker/sign.sh, no network) with the key of the app updater. The app checks the
//! signature against the public key built into it (plugins.updater.pubkey of tauri.conf.json)
//! and takes an asset only with its line in SHA256SUMS, and only if the bytes match it (and
//! the digest of the API, when it gives one). Downloads follow at most a few redirects, over
//! https and to the hosts of GitHub only; the size is limited.

use std::collections::HashMap;
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
const SUMS: &str = "SHA256SUMS";
const SUMS_SIG: &str = "SHA256SUMS.sig";
/// where the API and the downloads may lead (github.com redirects an asset to its storage)
const HOSTS: [&str; 4] = ["api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"];
const MAX_REDIRECTS: usize = 5;
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
    /// the digest of the API, lowercase hex
    pub digest: Option<String>,
    /// from the signed SHA256SUMS (verify_release); None: not installed
    pub sha256: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    pub tag: String,
    pub url: String,
    pub assets: Vec<Asset>,
    /// SHA256SUMS and its signature: (size, url)
    pub sums: Option<(u64, String)>,
    pub sums_sig: Option<(u64, String)>,
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
    /// false: not in the signed SHA256SUMS, it is not downloaded
    pub verified: bool,
    /// from SHA256SUMS: the router checks the file against it before opkg
    pub sha256: Option<String>,
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

/// the answer of /releases/latest: its ipk assets and SHA256SUMS from the expected place
pub fn parse_release(body: &[u8], prefix: &str) -> Result<Release> {
    let r: ApiRelease = serde_json::from_slice(body)
        .map_err(|e| TransportError::new("release_bad", format!("GitHub API: {e}")))?;
    let mut rel = Release { tag: r.tag_name, url: r.html_url, assets: vec![], sums: None, sums_sig: None };
    for a in r.assets.into_iter().filter(|a| a.browser_download_url.starts_with(prefix)) {
        match a.name.as_str() {
            SUMS => rel.sums = Some((a.size, a.browser_download_url)),
            SUMS_SIG => rel.sums_sig = Some((a.size, a.browser_download_url)),
            n if is_package(n) => rel.assets.push(Asset {
                digest: digest(a.digest.as_deref()), sha256: None, name: a.name, size: a.size, url: a.browser_download_url,
            }),
            _ => {}
        }
    }
    Ok(rel)
}

/// the public key of the app updater (tauri.conf.json, plugins.updater.pubkey): base64 of
/// the minisign public key file
pub fn updater_pubkey() -> String {
    let conf: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json")).expect("tauri.conf.json");
    conf["plugins"]["updater"]["pubkey"].as_str().expect("plugins.updater.pubkey").to_string()
}

fn b64_text(what: &str, b64: &str) -> Result<String> {
    let raw = base64::engine::general_purpose::STANDARD.decode(b64.trim())
        .map_err(|e| TransportError::new("release_signature", format!("{what}: {e}")))?;
    String::from_utf8(raw).map_err(|e| TransportError::new("release_signature", format!("{what}: {e}")))
}

/// name → sha256 of SHA256SUMS, if sig (the .sig of `tauri signer sign`: base64 of the
/// minisign signature) is a signature of it by pubkey (base64 of the public key file)
pub fn verify_sums(sums: &[u8], sig: &str, pubkey: &str) -> Result<HashMap<String, String>> {
    let bad = |e: minisign_verify::Error| TransportError::new("release_signature", format!("{SUMS}: {e}"));
    let pk = minisign_verify::PublicKey::decode(&b64_text("public key", pubkey)?).map_err(bad)?;
    let signature = minisign_verify::Signature::decode(&b64_text(SUMS_SIG, sig)?).map_err(bad)?;
    pk.verify(sums, &signature, false).map_err(bad)?;
    let text = std::str::from_utf8(sums).map_err(|e| TransportError::new("release_bad", format!("{SUMS}: {e}")))?;
    let mut res = HashMap::new();
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let (hash, name) = line.split_once(char::is_whitespace)
            .ok_or_else(|| TransportError::new("release_bad", format!("{SUMS}: {line}")))?;
        let name = name.trim_start().trim_start_matches('*');
        let hash = digest(Some(&format!("sha256:{hash}")))
            .ok_or_else(|| TransportError::new("release_bad", format!("{SUMS}: {line}")))?;
        res.insert(name.to_string(), hash);
    }
    Ok(res)
}

/// the sha256 of each asset from the signed SHA256SUMS; an API digest that differs refuses
pub fn apply_sums(release: &mut Release, sums: &HashMap<String, String>) -> Result<()> {
    for a in &mut release.assets {
        a.sha256 = sums.get(&a.name).cloned();
        if let (Some(s), Some(d)) = (&a.sha256, &a.digest) {
            if s != d {
                return Err(TransportError::new("release_digest", format!("{}: {SUMS} says {s}, the API {d}", a.name)));
            }
        }
    }
    Ok(())
}

/// redirects: a few, https, the hosts of GitHub
pub fn redirect_allowed(url: &reqwest::Url, hops: usize) -> bool {
    hops < MAX_REDIRECTS && url.scheme() == "https" && url.host_str().is_some_and(|h| HOSTS.contains(&h))
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
    let redirects = reqwest::redirect::Policy::custom(|a| {
        if redirect_allowed(a.url(), a.previous().len()) { a.follow() } else { a.error("redirect not allowed") }
    });
    // the GitHub API refuses requests without a User-Agent
    reqwest::Client::builder()
        .use_preconfigured_tls(tls)
        .redirect(redirects)
        .https_only(true)
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
        return Err(TransportError::new("release_no_digest", format!("{}: not in the signed {SUMS}", a.name)));
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

async fn get_small(http: &reqwest::Client, what: &str, (size, url): &(u64, String)) -> Result<Vec<u8>> {
    if *size > 64 << 10 {
        return Err(TransportError::new("release_too_big", format!("{what}: {size} bytes")));
    }
    let r = http.get(url).timeout(DOWNLOAD_TIMEOUT).send().await.map_err(|e| net_error(what, e))?;
    if !r.status().is_success() {
        return Err(status_error(what, &r));
    }
    read_limited(r, *size, what).await
}

/// the release with the sha256 of the signed SHA256SUMS; release_unsigned without it,
/// release_signature with a signature not of pubkey
pub async fn verify_release(http: &reqwest::Client, mut r: Release, pubkey: &str) -> Result<Release> {
    let (Some(sums), Some(sig)) = (&r.sums, &r.sums_sig) else {
        return Err(TransportError::new("release_unsigned", format!("{}: no {SUMS} with {SUMS_SIG}", r.tag)));
    };
    let body = get_small(http, SUMS, sums).await?;
    let sig = get_small(http, SUMS_SIG, sig).await?;
    let map = verify_sums(&body, &String::from_utf8_lossy(&sig), pubkey)?;
    apply_sums(&mut r, &map)?;
    Ok(r)
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
    let http = client()?;
    let r = fetch_release(&http, &api_url(), &download_prefix()).await?;
    let r = verify_release(&http, r, &updater_pubkey()).await?;
    let info = ReleaseInfo {
        tag: r.tag.clone(),
        url: r.url.clone(),
        assets: r.assets.iter()
            .map(|a| AssetInfo { name: a.name.clone(), size: a.size, verified: a.sha256.is_some(), sha256: a.sha256.clone() })
            .collect(),
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
    // a key made for these tests only (tauri signer generate -p ""), and with it
    // `tauri signer sign SHA256SUMS` of SUMS_B64: "<SHA_ABC>  luci-app-xvpn_0.3.0-r1_all.ipk\n"
    const TEST_PUB: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDZBODU0RUVDQkQ4NEExMTUKUldRVm9ZUzk3RTZGYWxNMUcxdXVndWRsa29KOHFEZ0dvMUlRSjBPNzNhK3ZqS29sMFIwMzgwS08K";
    const TEST_SIG: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVRVm9ZUzk3RTZGYWlaTmpRZTlxS0pxZ1BjUE8yZ1V4ZStOd2Fyb3ZWZXRWOWdOWW5iT3htTXNtekdpcDBlL0dmYjU3QkdjYUFWeXBLZ3RLaGQwbGQxQVJsYnQrODlVTVE4PQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzkzNTIwNzkxCWZpbGU6U0hBMjU2U1VNUwphR3dTT0xvdGdQbVE2RU8yZTVLbVZzMGcyL2wrY2RCQlNIY1I1OXJNdmt1YUVoNi95TElxSE0wREJNdXZHdGRMMUp5Q1ZzZ2xsZkhraHQxM29ZWm1EZz09Cg==";

    fn sums() -> Vec<u8> {
        format!("{SHA_ABC}  luci-app-xvpn_0.3.0-r1_all.ipk\n").into_bytes()
    }

    fn api_answer(prefix: &str) -> String {
        let a = |name: &str, size: usize, digest: serde_json::Value| serde_json::json!({
            "name": name, "size": size, "digest": digest, "browser_download_url": format!("{prefix}v0.3.0/{name}"),
        });
        serde_json::json!({
            "tag_name": "v0.3.0",
            "html_url": "https://github.com/Arseso/openwrt-xray-vless-client/releases/tag/v0.3.0",
            "assets": [
                a("luci-app-xvpn_0.3.0-r1_all.ipk", 3, format!("sha256:{}", SHA_ABC.to_uppercase()).into()),
                a("luci-i18n-xvpn-ru_0.3.0-r1_all.ipk", 3, serde_json::Value::Null),
                a(SUMS, sums().len(), serde_json::Value::Null),
                a(SUMS_SIG, TEST_SIG.len(), serde_json::Value::Null),
                a("xvpn_0.3.0_amd64.AppImage", 9, format!("sha256:{SHA_ABC}").into()),
                { "name": "luci-app-xvpn_0.3.0-r2_all.ipk", "size": 3, "digest": format!("sha256:{SHA_ABC}"),
                  "browser_download_url": "https://example.com/luci-app-xvpn_0.3.0-r2_all.ipk" },
                { "name": "luci-app-xvpn_0.3.0-r1_all.ipk.evil", "size": 3, "digest": null,
                  "browser_download_url": format!("{prefix}v0.3.0/luci-app-xvpn_0.3.0-r1_all.ipk.evil") }
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
        assert_eq!(names, ["luci-app-xvpn_0.3.0-r1_all.ipk", "luci-i18n-xvpn-ru_0.3.0-r1_all.ipk"]);
        assert_eq!(r.assets[0].digest.as_deref(), Some(SHA_ABC));
        assert_eq!(r.assets[1].digest, None);
        assert!(r.assets.iter().all(|a| a.sha256.is_none()));
        assert_eq!(r.sums.as_ref().unwrap().1, format!("{p}v0.3.0/SHA256SUMS"));
        assert!(r.sums_sig.is_some());
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

    #[test]
    fn signed_sums() {
        let m = verify_sums(&sums(), TEST_SIG, TEST_PUB).unwrap();
        assert_eq!(m.get("luci-app-xvpn_0.3.0-r1_all.ipk").map(String::as_str), Some(SHA_ABC));
        // another content, another key (the one of the app), garbage
        let mut other = sums();
        other[0] = b'c';
        assert_eq!(verify_sums(&other, TEST_SIG, TEST_PUB).unwrap_err().kind, "release_signature");
        assert_eq!(verify_sums(&sums(), TEST_SIG, &updater_pubkey()).unwrap_err().kind, "release_signature");
        assert_eq!(verify_sums(&sums(), "bm9wZQ==", TEST_PUB).unwrap_err().kind, "release_signature");

        let p = "https://github.com/x/";
        let mut r = parse_release(api_answer(p).as_bytes(), p).unwrap();
        apply_sums(&mut r, &m).unwrap();
        assert_eq!(r.assets[0].sha256.as_deref(), Some(SHA_ABC));
        // not in SHA256SUMS: not installed
        assert_eq!(r.assets[1].sha256, None);
        r.assets[0].digest = Some("00".repeat(32));
        assert_eq!(apply_sums(&mut r, &m).unwrap_err().kind, "release_digest");
    }

    #[test]
    fn redirects() {
        let u = |s: &str| reqwest::Url::parse(s).unwrap();
        assert!(redirect_allowed(&u("https://release-assets.githubusercontent.com/x"), 1));
        assert!(redirect_allowed(&u("https://objects.githubusercontent.com/x"), 0));
        assert!(!redirect_allowed(&u("http://objects.githubusercontent.com/x"), 0));
        assert!(!redirect_allowed(&u("https://evil.example/x"), 0));
        assert!(!redirect_allowed(&u("https://github.com.evil.example/x"), 0));
        assert!(!redirect_allowed(&u("https://github.com/x"), MAX_REDIRECTS));
        assert!(updater_pubkey().starts_with("dW50cnVzdGVk"));
    }

    /// a local HTTP server answering each connection with the next of `answers`
    async fn serve(answers: Vec<Vec<u8>>) -> String {
        serve_at(|_| answers).await
    }

    /// the same, the answers made knowing the URL of the server
    async fn serve_at(answers: impl FnOnce(&str) -> Vec<Vec<u8>>) -> String {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/", l.local_addr().unwrap());
        let answers = answers(&url);
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
    async fn release_sums_and_download_over_http() {
        // in order: the API, SHA256SUMS, its signature
        let base = serve_at(|url| vec![
            http("200 OK", "", api_answer(url).as_bytes()),
            http("200 OK", "", &sums()),
            http("200 OK", "", TEST_SIG.as_bytes()),
        ]).await;
        let r = fetch_release(&plain(), &base, &base).await.unwrap();
        let unsigned = Release { sums: None, ..r.clone() };
        assert_eq!(verify_release(&plain(), unsigned, TEST_PUB).await.unwrap_err().kind, "release_unsigned");
        let r = verify_release(&plain(), r, TEST_PUB).await.unwrap();
        assert_eq!(r.assets[0].sha256.as_deref(), Some(SHA_ABC));

        let file = serve(vec![http("200 OK", "", b"abc"), http("200 OK", "", b"abd"), http("200 OK", "", b"abcd")]).await;
        let mut a = r.assets[0].clone();
        a.url = file;
        assert_eq!(download(&plain(), &a).await.unwrap(), b"abc");
        assert_eq!(download(&plain(), &a).await.unwrap_err().kind, "release_digest");
        // more than the API said
        assert_eq!(download(&plain(), &a).await.unwrap_err().kind, "release_too_big");

        let mut unlisted = r.assets[1].clone();
        unlisted.url = "http://127.0.0.1:1/".into();
        assert_eq!(download(&plain(), &unlisted).await.unwrap_err().kind, "release_no_digest");
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
