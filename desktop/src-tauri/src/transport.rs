//! HTTP(S) to uhttpd /ubus. One reqwest client per profile, kept while its address and
//! pin stay the same (keep-alive for the poller). The JSON-RPC itself, the session and
//! its renewal are the web view's (src/api/ubus.ts); here only the request, the
//! timeouts and the certificate pin (pin.rs).

use std::collections::HashMap;
use std::error::Error as _;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;

use crate::error::{Result, TransportError};
use crate::pin::{PinFailure, PinVerifier};

/// connecting longer than this is "unreachable", however long the call may take
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
pub const MAX_TIMEOUT_MS: u64 = 120_000;

#[derive(Clone)]
struct Client {
    url: String,
    pin: Option<String>,
    http: reqwest::Client,
    verifier: Arc<PinVerifier>,
}

#[derive(Default)]
pub struct Http {
    clients: Mutex<HashMap<String, Client>>,
}

impl Http {
    /// POST body to <url>/ubus; key: the profile the client is kept for
    pub async fn post(&self, key: &str, url: &str, pin: Option<&str>, body: &Value, timeout_ms: u64) -> Result<Value> {
        let c = self.client(key, url, pin)?;
        post(&c.http, &c.verifier, &c.url, body, timeout_ms).await
    }

    /// after the address or pin of the profile changed
    pub fn forget(&self, key: &str) {
        self.clients.lock().unwrap().remove(key);
    }

    fn client(&self, key: &str, url: &str, pin: Option<&str>) -> Result<Client> {
        let mut clients = self.clients.lock().unwrap();
        if let Some(c) = clients.get(key) {
            if c.url == url && c.pin.as_deref() == pin {
                return Ok(c.clone());
            }
        }
        let (http, verifier) = build(pin.map(str::to_string))?;
        let c = Client { url: url.to_string(), pin: pin.map(str::to_string), http, verifier };
        clients.insert(key.to_string(), c.clone());
        Ok(c)
    }
}

pub fn build(pin: Option<String>) -> Result<(reqwest::Client, Arc<PinVerifier>)> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let verifier = Arc::new(PinVerifier::new(pin, provider.clone()));
    let tls = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| TransportError::new("tls", e.to_string()))?
        .dangerous()
        .with_custom_certificate_verifier(verifier.clone())
        .with_no_client_auth();
    let http = reqwest::Client::builder()
        .use_preconfigured_tls(tls)
        .connect_timeout(CONNECT_TIMEOUT)
        // the router is on the LAN: no system proxy, and no silent POST -> GET on a redirect
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("xvpn-desktop/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| TransportError::new("tls", e.to_string()))?;
    Ok((http, verifier))
}

pub async fn post(http: &reqwest::Client, verifier: &PinVerifier, url: &str, body: &Value, timeout_ms: u64) -> Result<Value> {
    let timeout = Duration::from_millis(timeout_ms.clamp(100, MAX_TIMEOUT_MS));
    let res = http.post(format!("{url}/ubus")).timeout(timeout).json(body).send().await;
    let res = match res {
        Ok(r) => r,
        Err(e) => return Err(request_error(e, verifier)),
    };
    let status = res.status();
    if !status.is_success() {
        let mut err = TransportError::new("http", format!("HTTP {status}"));
        if let Some(loc) = res.headers().get(reqwest::header::LOCATION).and_then(|v| v.to_str().ok()) {
            err.message = format!("HTTP {status}, redirect to {loc}");
        }
        err.status = Some(status.as_u16());
        return Err(err);
    }
    match res.json::<Value>().await {
        Ok(v) => Ok(v),
        Err(e) if e.is_timeout() => Err(TransportError::new("timeout", e.to_string())),
        Err(e) => Err(TransportError::new("bad_response", format!("not JSON: {e}"))),
    }
}

fn request_error(e: reqwest::Error, verifier: &PinVerifier) -> TransportError {
    match verifier.take_failure() {
        Some(PinFailure::Unknown { seen }) => {
            let mut err = TransportError::new("tls_unknown", "the router certificate is not pinned yet");
            err.fingerprint = Some(seen);
            return err;
        }
        Some(PinFailure::Changed { seen, pinned }) => {
            let mut err = TransportError::new("tls_changed", "the router certificate differs from the pinned one");
            err.fingerprint = Some(seen);
            err.pinned = Some(pinned);
            return err;
        }
        None => {}
    }
    let msg = chain(&e);
    if e.is_timeout() {
        TransportError::new("timeout", msg)
    } else if is_tls(&e) {
        TransportError::new("tls", msg)
    } else if e.is_connect() || e.is_request() {
        TransportError::new("unreachable", msg)
    } else {
        TransportError::new("bad_response", msg)
    }
}

/// the messages of the whole chain: reqwest alone says only "error sending request"
fn chain(e: &reqwest::Error) -> String {
    let mut msg = e.to_string();
    let mut src = e.source();
    while let Some(s) = src {
        msg = format!("{msg}: {s}");
        src = s.source();
    }
    msg
}

fn is_tls(e: &reqwest::Error) -> bool {
    let mut src = e.source();
    while let Some(s) = src {
        if s.downcast_ref::<rustls::Error>().is_some() {
            return true;
        }
        // io::Error::source() skips the error it wraps
        if let Some(inner) = s.downcast_ref::<std::io::Error>().and_then(|io| io.get_ref()) {
            if inner.downcast_ref::<rustls::Error>().is_some() {
                return true;
            }
        }
        src = s.source();
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pin::fingerprint;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    /// an HTTPS server with a fresh self-signed certificate answering every request with
    /// a JSON-RPC result; returns its url and the certificate fingerprint
    fn https_server() -> (String, String) {
        let c = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
        let fp = fingerprint(c.cert.der().as_ref());
        let key = rustls::pki_types::PrivateKeyDer::Pkcs8(c.key_pair.serialize_der().into());
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let cfg = Arc::new(
            rustls::ServerConfig::builder_with_provider(provider)
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(vec![c.cert.der().clone()], key)
                .unwrap(),
        );
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("https://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { continue };
                let cfg = cfg.clone();
                std::thread::spawn(move || {
                    let conn = rustls::ServerConnection::new(cfg).unwrap();
                    let mut tls = rustls::StreamOwned::new(conn, stream);
                    let mut buf = [0u8; 4096];
                    // one request per connection is enough here
                    let Ok(n) = tls.read(&mut buf) else { return };
                    if n == 0 {
                        return;
                    }
                    let body = r#"{"jsonrpc":"2.0","id":1,"result":[0,{"ok":true}]}"#;
                    let _ = write!(
                        tls,
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = tls.flush();
                    tls.conn.send_close_notify();
                    let _ = tls.flush();
                });
            }
        });
        (url, fp)
    }

    fn body() -> Value {
        serde_json::json!({ "jsonrpc": "2.0", "id": 1, "method": "list", "params": ["*"] })
    }

    #[tokio::test]
    async fn tofu_against_a_real_tls_server() {
        let (url, fp) = https_server();
        let http = Http::default();

        // first connection: refused, the fingerprint comes back for the user
        let err = http.post("p", &url, None, &body(), 5000).await.unwrap_err();
        assert_eq!(err.kind, "tls_unknown", "{err}");
        assert_eq!(err.fingerprint.as_deref(), Some(fp.as_str()));

        // pinned: goes through
        let v = http.post("p", &url, Some(&fp), &body(), 5000).await.unwrap();
        assert_eq!(v["result"][1]["ok"], true);

        // another certificate on the same address: refused with both fingerprints
        let other = "00:".repeat(31) + "00";
        let err = http.post("p", &url, Some(&other), &body(), 5000).await.unwrap_err();
        assert_eq!(err.kind, "tls_changed", "{err}");
        assert_eq!(err.fingerprint.as_deref(), Some(fp.as_str()));
        assert_eq!(err.pinned.as_deref(), Some(other.as_str()));
    }

    #[tokio::test]
    async fn closed_port_is_unreachable() {
        let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let err = Http::default().post("p", &format!("http://127.0.0.1:{port}"), None, &body(), 2000).await.unwrap_err();
        assert_eq!(err.kind, "unreachable", "{err}");
    }

    #[tokio::test]
    async fn silent_server_times_out() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        // accepts and never answers
        std::thread::spawn(move || {
            let _held: Vec<_> = listener.incoming().take(4).collect();
            std::thread::sleep(Duration::from_secs(10));
        });
        let err = Http::default().post("p", &url, None, &body(), 500).await.unwrap_err();
        assert_eq!(err.kind, "timeout", "{err}");
    }
}
