//! "Am I behind the VPN" (#78): the public IPv4 and IPv6 of this PC as a public echo
//! service sees them, and the addresses of a server name. The comparison is the web
//! view's (src/core/vpncheck.ts). Asked only on demand: each check is a request to a
//! third party, named in the window; the second service only when the user asks for it.

use std::net::{IpAddr, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

use tauri::ipc::Invoke;
use tauri::Wry;

/// plain-text answers with the caller's address over one IP family
const IPIFY: [&str; 2] = ["https://api4.ipify.org", "https://api6.ipify.org"];
const ICANHAZIP: [&str; 2] = ["https://ipv4.icanhazip.com", "https://ipv6.icanhazip.com"];
const RESOLVE_TIMEOUT: Duration = Duration::from_secs(5);

fn client() -> Result<reqwest::Client, String> {
    let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
    let tls = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .map_err(|e| e.to_string())?
        .with_root_certificates(roots)
        .with_no_client_auth();
    // no User-Agent: nothing that tells the service which app asks
    reqwest::Client::builder()
        .use_preconfigured_tls(tls)
        .timeout(Duration::from_secs(6))
        .build()
        .map_err(|e| e.to_string())
}

pub fn parse_ip(body: &str) -> Option<IpAddr> {
    body.trim().parse().ok()
}

pub fn service(v6: bool, other: bool) -> &'static str {
    let i = usize::from(v6);
    if other { ICANHAZIP[i] } else { IPIFY[i] }
}

#[derive(serde::Serialize)]
struct PublicIp {
    ip: String,
    source: &'static str,
}

/// the address the internet sees this PC at over IPv4 (v6 false) or IPv6; `other`: the
/// second service, when the user asked for it
#[tauri::command]
async fn vpn_public_ip(v6: bool, other: bool) -> Result<PublicIp, String> {
    let url = service(v6, other);
    let r = client()?.get(url).send().await.map_err(|e| format!("{url}: {e}"))?;
    if !r.status().is_success() {
        return Err(format!("{url}: HTTP {}", r.status()));
    }
    let body = r.text().await.map_err(|e| format!("{url}: {e}"))?;
    match parse_ip(&body) {
        Some(ip) if ip.is_ipv6() == v6 => Ok(PublicIp { ip: ip.to_string(), source: url }),
        _ => Err(format!("{url}: not an address")),
    }
}

/// the addresses of a server name, as this PC resolves it (a hung resolver gives up)
#[tauri::command]
async fn vpn_resolve(host: String) -> Result<Vec<String>, String> {
    if let Ok(ip) = host.trim_matches(['[', ']']).parse::<IpAddr>() {
        return Ok(vec![ip.to_string()]);
    }
    let job = tauri::async_runtime::spawn_blocking(move || {
        (host.as_str(), 443).to_socket_addrs().map(|a| {
            let mut v: Vec<String> = a.map(|s| s.ip().to_string()).collect();
            v.dedup();
            v
        })
    });
    match tokio::time::timeout(RESOLVE_TIMEOUT, job).await {
        Ok(Ok(r)) => r.map_err(|e| e.to_string()),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err("name resolution timed out".into()),
    }
}

/// commands named vpn_*; lib.rs routes them here
pub fn handler() -> impl Fn(Invoke<Wry>) -> bool + Send + Sync + 'static {
    tauri::generate_handler![vpn_public_ip, vpn_resolve]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn echo_answers() {
        assert_eq!(parse_ip("203.0.113.7\n"), Some("203.0.113.7".parse().unwrap()));
        assert_eq!(parse_ip("2001:db8::1"), Some("2001:db8::1".parse().unwrap()));
        assert_eq!(parse_ip("<html>"), None);
        assert_eq!(service(false, false), "https://api4.ipify.org");
        assert_eq!(service(true, true), "https://ipv6.icanhazip.com");
    }

    #[tokio::test]
    async fn literal_addresses_are_not_resolved() {
        assert_eq!(vpn_resolve("[2001:db8::1]".into()).await.unwrap(), vec!["2001:db8::1"]);
        assert_eq!(vpn_resolve("localhost".into()).await.map(|v| !v.is_empty()), Ok(true));
    }
}
