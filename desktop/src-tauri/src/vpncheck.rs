//! "Am I behind the VPN" (#78): the public IP of this PC as a public echo service sees
//! it, and the addresses of a server name. The comparison is the web view's
//! (src/core/vpncheck.ts). Asked only on demand: each check is a request to a third party.

use std::net::{IpAddr, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

use tauri::ipc::Invoke;
use tauri::Wry;

/// plain-text answers with the caller's address, tried in order
const ECHO: [&str; 3] = ["https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com"];

fn client() -> Result<reqwest::Client, String> {
    let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
    let tls = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .map_err(|e| e.to_string())?
        .with_root_certificates(roots)
        .with_no_client_auth();
    reqwest::Client::builder()
        .use_preconfigured_tls(tls)
        .timeout(Duration::from_secs(6))
        .user_agent(concat!("xvpn-desktop/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())
}

pub fn parse_ip(body: &str) -> Option<IpAddr> {
    body.trim().parse().ok()
}

#[derive(serde::Serialize)]
struct PublicIp {
    ip: String,
    source: &'static str,
}

/// the address the internet sees this PC at (through the system proxy, if any: that is
/// the way the browser goes too)
#[tauri::command]
async fn vpn_public_ip() -> Result<PublicIp, String> {
    let c = client()?;
    let mut last = String::from("no answer");
    for url in ECHO {
        match c.get(url).send().await {
            Ok(r) if r.status().is_success() => match r.text().await.ok().as_deref().and_then(parse_ip) {
                Some(ip) => return Ok(PublicIp { ip: ip.to_string(), source: url }),
                None => last = format!("{url}: not an address"),
            },
            Ok(r) => last = format!("{url}: HTTP {}", r.status()),
            Err(e) => last = format!("{url}: {e}"),
        }
    }
    Err(last)
}

/// the addresses of a server name, as this PC resolves it
#[tauri::command]
async fn vpn_resolve(host: String) -> Result<Vec<String>, String> {
    if let Ok(ip) = host.trim_matches(['[', ']']).parse::<IpAddr>() {
        return Ok(vec![ip.to_string()]);
    }
    tauri::async_runtime::spawn_blocking(move || {
        (host.as_str(), 443)
            .to_socket_addrs()
            .map(|a| {
                let mut v: Vec<String> = a.map(|s| s.ip().to_string()).collect();
                v.dedup();
                v
            })
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
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
    }

    #[tokio::test]
    async fn literal_addresses_are_not_resolved() {
        assert_eq!(vpn_resolve("[2001:db8::1]".into()).await.unwrap(), vec!["2001:db8::1"]);
        assert_eq!(vpn_resolve("localhost".into()).await.map(|v| !v.is_empty()), Ok(true));
    }
}
