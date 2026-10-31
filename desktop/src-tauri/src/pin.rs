//! Trust on first use for the self-signed certificate of uhttpd: the router is trusted
//! by the SHA-256 of its leaf certificate, not by a CA (uhttpd makes its own with px5g,
//! for an address nobody can get a CA certificate for). The handshake signatures are
//! still checked, so the peer holds the key of the pinned certificate.
//!
//! Without a pin the handshake fails with Unknown and the fingerprint seen: the UI
//! shows it, the user confirms, the profile stores it. A pin that does not match fails
//! with Changed until the user explicitly trusts the new one. The PinFailure travels
//! inside the TLS error of that very connection (CertificateError::Other), so
//! concurrent requests each get their own.

use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{verify_tls12_signature, verify_tls13_signature, CryptoProvider};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use sha2::{Digest, Sha256};

/// AA:BB:... of SHA-256 over the DER of the certificate (as `openssl x509 -fingerprint -sha256`)
pub fn fingerprint(der: &[u8]) -> String {
    Sha256::digest(der)
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(":")
}

/// a fingerprint as typed or stored: upper case with colons; None for anything else
pub fn normalize(fp: &str) -> Option<String> {
    let hex: String = fp.chars().filter(|c| !matches!(c, ':' | ' ')).collect();
    if hex.len() != 64 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let hex = hex.to_ascii_uppercase();
    Some(
        hex.as_bytes()
            .chunks(2)
            .map(|c| std::str::from_utf8(c).unwrap())
            .collect::<Vec<_>>()
            .join(":"),
    )
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PinFailure {
    /// no pin yet: the certificate presented
    Unknown { seen: String },
    /// the pin does not match
    Changed { seen: String, pinned: String },
}

impl std::fmt::Display for PinFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PinFailure::Unknown { seen } => write!(f, "certificate {seen} is not pinned"),
            PinFailure::Changed { seen, pinned } => write!(f, "certificate {seen} instead of the pinned {pinned}"),
        }
    }
}

impl std::error::Error for PinFailure {}

/// the PinFailure inside a TLS error, if that is why the handshake failed
pub fn failure_of(e: &rustls::Error) -> Option<&PinFailure> {
    match e {
        rustls::Error::InvalidCertificate(rustls::CertificateError::Other(o)) => o.0.downcast_ref::<PinFailure>(),
        _ => None,
    }
}

pub fn check(pinned: Option<&str>, seen: &str) -> Result<(), PinFailure> {
    match pinned {
        Some(p) if p == seen => Ok(()),
        Some(p) => Err(PinFailure::Changed { seen: seen.to_string(), pinned: p.to_string() }),
        None => Err(PinFailure::Unknown { seen: seen.to_string() }),
    }
}

#[derive(Debug)]
pub struct PinVerifier {
    pinned: Option<String>,
    provider: Arc<CryptoProvider>,
}

impl PinVerifier {
    pub fn new(pinned: Option<String>, provider: Arc<CryptoProvider>) -> Self {
        PinVerifier { pinned, provider }
    }
}

impl ServerCertVerifier for PinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let seen = fingerprint(end_entity.as_ref());
        match check(self.pinned.as_deref(), &seen) {
            Ok(()) => Ok(ServerCertVerified::assertion()),
            Err(f) => Err(rustls::Error::InvalidCertificate(rustls::CertificateError::Other(rustls::OtherError(Arc::new(f))))),
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cert() -> CertificateDer<'static> {
        let c = rcgen::generate_simple_self_signed(vec!["192.168.1.1".into()]).unwrap();
        c.cert.der().clone()
    }

    fn verify(v: &PinVerifier, c: &CertificateDer<'_>) -> Result<ServerCertVerified, rustls::Error> {
        let name = ServerName::try_from("192.168.1.1").unwrap();
        v.verify_server_cert(c, &[], &name, &[], UnixTime::now())
    }

    fn provider() -> Arc<CryptoProvider> {
        Arc::new(rustls::crypto::ring::default_provider())
    }

    #[test]
    fn fingerprint_format() {
        let fp = fingerprint(b"abc");
        assert_eq!(fp.len(), 32 * 3 - 1);
        assert!(fp.starts_with("BA:78:16:BF:"));
        assert_eq!(normalize(&fp.to_lowercase().replace(':', "")), Some(fp.clone()));
        assert_eq!(normalize(&fp), Some(fp));
        assert_eq!(normalize("AB:CD"), None);
        assert_eq!(normalize(&"zz".repeat(32)), None);
    }

    #[test]
    fn first_connection_reports_the_fingerprint() {
        let c = cert();
        let v = PinVerifier::new(None, provider());
        let e = verify(&v, &c).unwrap_err();
        assert_eq!(failure_of(&e), Some(&PinFailure::Unknown { seen: fingerprint(c.as_ref()) }));
    }

    #[test]
    fn pinned_certificate_passes() {
        let c = cert();
        let v = PinVerifier::new(Some(fingerprint(c.as_ref())), provider());
        assert!(verify(&v, &c).is_ok());
    }

    #[test]
    fn another_certificate_is_refused() {
        let (old, new) = (cert(), cert());
        let pinned = fingerprint(old.as_ref());
        let v = PinVerifier::new(Some(pinned.clone()), provider());
        let e = verify(&v, &new).unwrap_err();
        assert_eq!(failure_of(&e), Some(&PinFailure::Changed { seen: fingerprint(new.as_ref()), pinned }));
        // each handshake carries its own: a check of the old certificate meanwhile passes
        assert!(verify(&v, &old).is_ok());
        assert!(failure_of(&e).is_some());
    }
}
