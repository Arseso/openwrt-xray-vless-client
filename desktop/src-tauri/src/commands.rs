//! Commands of the core: the ubus transport and the router profiles. Their names have
//! no tray_/notify_ prefix: lib.rs sends those to tray.rs and notifications.rs.

use std::sync::Arc;

use serde_json::{json, Value};
use tauri::ipc::Invoke;
use tauri::{State, Wry};

use crate::error::{Result, TransportError};
use crate::profiles::{Profile, Profiles};
use crate::transport::Http;
use crate::{gateway, pin};

pub struct Core {
    pub profiles: Arc<Profiles>,
    pub http: Http,
}

/// the commands of this module; lib.rs routes every name without a module prefix here
pub fn handler() -> impl Fn(Invoke<Wry>) -> bool + Send + Sync + 'static {
    tauri::generate_handler![
        ubus_request,
        ubus_login,
        profiles_list,
        profile_save,
        profile_delete,
        profile_set_password,
        profile_has_password,
        profile_trust,
        default_gateway,
    ]
}

const ANON_SID: &str = "00000000000000000000000000000000";

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> Result<T> + Send + 'static) -> Result<T> {
    tauri::async_runtime::spawn_blocking(f)
        .await
        .map_err(|e| TransportError::new("keyring", e.to_string()))?
}

/// one JSON-RPC request (call or list) to /ubus of the profile, the answer as is
#[tauri::command]
pub async fn ubus_request(core: State<'_, Core>, profile_id: String, body: Value, timeout_ms: u64) -> Result<Value> {
    let p = core.profiles.get(&profile_id)?;
    core.http.post(&p.id, &p.url, p.fingerprint.as_deref(), &body, timeout_ms).await
}

/// session login with the user of the profile and its stored password
#[tauri::command]
pub async fn ubus_login(core: State<'_, Core>, profile_id: String, timeout_ms: u64) -> Result<Value> {
    let p = core.profiles.get(&profile_id)?;
    let (profiles, id) = (core.profiles.clone(), p.id.clone());
    let password = blocking(move || profiles.password(&id)).await?;
    let body = json!({
        "jsonrpc": "2.0", "id": 0, "method": "call",
        "params": [ANON_SID, "session", "login", { "username": p.username, "password": password }],
    });
    core.http.post(&p.id, &p.url, p.fingerprint.as_deref(), &body, timeout_ms).await
}

#[tauri::command]
pub fn profiles_list(core: State<'_, Core>) -> Vec<Profile> {
    core.profiles.list()
}

#[tauri::command]
pub fn profile_save(core: State<'_, Core>, profile: Profile) -> Result<Profile> {
    let p = core.profiles.save(profile)?;
    core.http.forget(&p.id);
    Ok(p)
}

#[tauri::command]
pub async fn profile_delete(core: State<'_, Core>, id: String) -> Result<()> {
    core.profiles.delete(&id)?;
    core.http.forget(&id);
    let profiles = core.profiles.clone();
    blocking(move || profiles.forget_password(&id)).await
}

#[tauri::command]
pub async fn profile_set_password(core: State<'_, Core>, id: String, password: String, remember: bool) -> Result<()> {
    core.profiles.get(&id)?;
    let profiles = core.profiles.clone();
    blocking(move || profiles.set_password(&id, &password, remember)).await
}

#[tauri::command]
pub async fn profile_has_password(core: State<'_, Core>, id: String) -> Result<bool> {
    let profiles = core.profiles.clone();
    blocking(move || profiles.has_password(&id)).await
}

/// pins the certificate the user confirmed (the fingerprint of tls_unknown / tls_changed)
#[tauri::command]
pub fn profile_trust(core: State<'_, Core>, id: String, fingerprint: String) -> Result<Profile> {
    let fp = pin::normalize(&fingerprint).ok_or_else(|| TransportError::new("tls", "invalid fingerprint"))?;
    let p = core.profiles.trust(&id, &fp)?;
    core.http.forget(&id);
    Ok(p)
}

#[tauri::command]
pub fn default_gateway() -> Option<String> {
    gateway::default_gateway().map(|ip| ip.to_string())
}
