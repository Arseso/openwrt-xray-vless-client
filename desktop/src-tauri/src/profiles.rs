//! Router profiles in <app config dir>/profiles.json; the passwords are not there but
//! in the system credential store (keyring: Windows Credential Manager, Secret Service
//! on Linux), or in memory for this run when the user chose not to remember it.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::error::{Result, TransportError};
use crate::pin;

/// keyring service name: the app identifier (tauri.conf.json)
const SERVICE: &str = "io.github.arseso.xvpn";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Profile {
    pub id: String,
    pub name: String,
    /// http(s)://host[:port]
    pub url: String,
    pub username: String,
    /// SHA-256 of the pinned certificate, HTTPS only
    #[serde(default)]
    pub fingerprint: Option<String>,
}

#[derive(Serialize, Deserialize, Default)]
struct File {
    profiles: Vec<Profile>,
}

pub struct Profiles {
    path: PathBuf,
    list: Mutex<Vec<Profile>>,
    /// passwords not to be remembered
    session: Mutex<HashMap<String, String>>,
}

/// scheme://host[:port] of what the user typed (host in lower case, no default port);
/// https:// when there is no scheme: the password goes over HTTP only when asked for
pub fn normalize_url(s: &str) -> Result<String> {
    let s = s.trim().trim_end_matches('/');
    let s = s.strip_suffix("/ubus").unwrap_or(s);
    let full = if s.contains("://") { s.to_string() } else { format!("https://{s}") };
    let u = reqwest::Url::parse(&full).map_err(|e| TransportError::new("invalid_url", format!("{s}: {e}")))?;
    if !matches!(u.scheme(), "http" | "https") {
        return Err(TransportError::new("invalid_url", format!("{s}: only http and https")));
    }
    let host = u.host_str().filter(|h| !h.is_empty()).ok_or_else(|| TransportError::new("invalid_url", format!("{s}: no host")))?;
    let host = if host.contains(':') && !host.starts_with('[') { format!("[{host}]") } else { host.to_string() };
    Ok(match u.port() {
        Some(p) => format!("{}://{host}:{p}", u.scheme()),
        None => format!("{}://{host}", u.scheme()),
    })
}

impl Profiles {
    pub fn load(dir: PathBuf) -> Self {
        let path = dir.join("profiles.json");
        let list = std::fs::read(&path)
            .ok()
            .and_then(|b| serde_json::from_slice::<File>(&b).ok())
            .map(|f| f.profiles)
            .unwrap_or_default();
        Profiles { path, list: Mutex::new(list), session: Mutex::new(HashMap::new()) }
    }

    pub fn list(&self) -> Vec<Profile> {
        self.list.lock().unwrap().clone()
    }

    pub fn get(&self, id: &str) -> Result<Profile> {
        self.list
            .lock()
            .unwrap()
            .iter()
            .find(|p| p.id == id)
            .cloned()
            .ok_or_else(|| TransportError::new("no_profile", format!("no profile {id}")))
    }

    /// adds or replaces by id
    pub fn save(&self, mut p: Profile) -> Result<Profile> {
        if p.id.trim().is_empty() {
            return Err(TransportError::new("no_profile", "empty profile id"));
        }
        p.url = normalize_url(&p.url)?;
        p.name = p.name.trim().to_string();
        if p.name.is_empty() {
            p.name = p.url.clone();
        }
        p.username = p.username.trim().to_string();
        if p.username.is_empty() {
            p.username = "root".into();
        }
        p.fingerprint = match p.fingerprint.as_deref() {
            Some(fp) if p.url.starts_with("https://") => {
                Some(pin::normalize(fp).ok_or_else(|| TransportError::new("invalid_url", "invalid certificate fingerprint"))?)
            }
            _ => None,
        };
        let mut list = self.list.lock().unwrap();
        match list.iter_mut().find(|x| x.id == p.id) {
            Some(x) => {
                // another scheme, host or port is another certificate: the pin goes with
                // the old address (both normalized: case, slash or :443 change nothing)
                if x.url != p.url {
                    p.fingerprint = None;
                }
                *x = p.clone()
            }
            None => list.push(p.clone()),
        }
        self.write(&list)?;
        Ok(p)
    }

    pub fn delete(&self, id: &str) -> Result<()> {
        let mut list = self.list.lock().unwrap();
        list.retain(|p| p.id != id);
        self.write(&list)?;
        drop(list);
        self.session.lock().unwrap().remove(id);
        Ok(())
    }

    pub fn trust(&self, id: &str, fingerprint: &str) -> Result<Profile> {
        let mut p = self.get(id)?;
        p.fingerprint = Some(fingerprint.to_string());
        self.save(p)
    }

    fn write(&self, list: &[Profile]) -> Result<()> {
        let err = |e: std::io::Error| TransportError::new("keyring", format!("{}: {e}", self.path.display()));
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).map_err(err)?;
        }
        let json = serde_json::to_vec_pretty(&File { profiles: list.to_vec() }).unwrap();
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, json).map_err(err)?;
        std::fs::rename(&tmp, &self.path).map_err(err)
    }

    // the password calls block on D-Bus / the credential manager: commands run them
    // with spawn_blocking

    pub fn set_password(&self, id: &str, password: &str, remember: bool) -> Result<()> {
        if remember {
            entry(id)?.set_password(password).map_err(keyring_error)?;
            self.session.lock().unwrap().remove(id);
        } else {
            self.session.lock().unwrap().insert(id.to_string(), password.to_string());
            // "do not remember" is the way out when the credential store does not work:
            // a stale stored password is only a leftover then, not an error
            if let Err(e) = forget_stored(id) {
                eprintln!("xvpn: cannot remove the stored password of {id}: {e}");
            }
        }
        Ok(())
    }

    pub fn password(&self, id: &str) -> Result<String> {
        if let Some(p) = self.session.lock().unwrap().get(id) {
            return Ok(p.clone());
        }
        match entry(id)?.get_password() {
            Ok(p) => Ok(p),
            Err(keyring::Error::NoEntry) => Err(TransportError::new("no_password", "no saved password")),
            Err(e) => Err(keyring_error(e)),
        }
    }

    pub fn has_password(&self, id: &str) -> Result<bool> {
        match self.password(id) {
            Ok(_) => Ok(true),
            Err(e) if e.kind == "no_password" => Ok(false),
            Err(e) => Err(e),
        }
    }

    pub fn forget_password(&self, id: &str) -> Result<()> {
        self.session.lock().unwrap().remove(id);
        forget_stored(id)
    }
}

fn entry(id: &str) -> Result<keyring::Entry> {
    keyring::Entry::new(SERVICE, &format!("profile:{id}")).map_err(keyring_error)
}

fn forget_stored(id: &str) -> Result<()> {
    match entry(id)?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(keyring_error(e)),
    }
}

fn keyring_error(e: keyring::Error) -> TransportError {
    TransportError::new("keyring", e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls() {
        assert_eq!(normalize_url("192.168.1.1").unwrap(), "https://192.168.1.1");
        assert_eq!(normalize_url("HTTPS://Router.LAN:443/").unwrap(), "https://router.lan");
        assert_eq!(normalize_url(" https://router.lan:8443/ ").unwrap(), "https://router.lan:8443");
        assert_eq!(normalize_url("http://10.0.0.1/ubus").unwrap(), "http://10.0.0.1");
        assert_eq!(normalize_url("http://10.0.0.1/cgi-bin/luci").unwrap(), "http://10.0.0.1");
        assert_eq!(normalize_url("https://[fd00::1]").unwrap(), "https://[fd00::1]");
        assert_eq!(normalize_url("http://10.0.0.1:80").unwrap(), "http://10.0.0.1");
        assert!(normalize_url("ftp://10.0.0.1").is_err());
        assert!(normalize_url("").is_err());
    }

    #[test]
    fn store_round_trip() {
        let dir = std::env::temp_dir().join(format!("xvpn-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let s = Profiles::load(dir.clone());
        let fp = "ab".repeat(32);
        let p = s
            .save(Profile { id: "a".into(), name: " Home ".into(), url: "https://192.168.1.1".into(), username: "".into(), fingerprint: Some(fp) })
            .unwrap();
        assert_eq!(p.name, "Home");
        assert_eq!(p.username, "root");
        assert!(p.fingerprint.as_deref().unwrap().starts_with("AB:AB:"));
        // http: no pin kept
        let q = s
            .save(Profile { id: "b".into(), name: "".into(), url: "http://10.0.0.1".into(), username: "u".into(), fingerprint: Some("x".into()) })
            .unwrap();
        assert_eq!(q.fingerprint, None);
        assert_eq!(q.name, "http://10.0.0.1");
        // the same address written otherwise keeps the pin, another one drops it
        let same = s.save(Profile { url: "HTTPS://192.168.1.1:443/".into(), ..p.clone() }).unwrap();
        assert_eq!(same.fingerprint, p.fingerprint);
        let moved = s.save(Profile { url: "https://192.168.1.2".into(), ..p.clone() }).unwrap();
        assert_eq!(moved.fingerprint, None);
        let again = Profiles::load(dir.clone());
        assert_eq!(again.list(), s.list());
        assert_eq!(again.list().len(), 2);
        again.delete("a").unwrap();
        assert_eq!(Profiles::load(dir.clone()).list().len(), 1);
        assert_eq!(again.get("a").unwrap_err().kind, "no_profile");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn password_for_this_run_only() {
        let dir = std::env::temp_dir().join(format!("xvpn-test-pw-{}", std::process::id()));
        let s = Profiles::load(dir);
        // works whether a credential store runs here or not (the docker build has none):
        // remember: false must not fail on removing a stored one
        s.set_password("x", "secret", false).unwrap();
        assert_eq!(s.password("x").unwrap(), "secret");
        assert!(s.has_password("x").unwrap());
    }
}
