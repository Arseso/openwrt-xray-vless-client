//! Updates of the app (#81): tauri-plugin-updater against latest.json of the latest GitHub
//! release (the endpoint and the public key are in tauri.conf.json, plugins.updater).
//! Nothing happens by itself: the web view asks with updater_check (a button), shows what
//! is there and calls updater_install only after the user agreed. The signature of the
//! package is checked by the plugin against the public key before anything is installed.
//!
//! The plugin's own JS API is not granted to the web view (no capability for it): these
//! two commands are all it can do. Installable: the NSIS setup on Windows and the AppImage
//! on Linux; a deb installation is told to take the deb of the release instead.

use std::sync::Mutex;

use serde::Serialize;
use tauri::ipc::Invoke;
use tauri::{App, AppHandle, Manager, State, Wry};
use tauri_plugin_updater::{Update, UpdaterExt};

/// the update found by the last check, kept for updater_install
#[derive(Default)]
struct Pending(Mutex<Option<Update>>);

pub fn init(app: &mut App) -> tauri::Result<()> {
    app.handle().plugin(tauri_plugin_updater::Builder::new().build())?;
    app.manage(Pending::default());
    Ok(())
}

/// commands named updater_*; lib.rs routes them here
pub fn handler() -> impl Fn(Invoke<Wry>) -> bool + Send + Sync + 'static {
    tauri::generate_handler![updater_check, updater_install]
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Available {
    pub version: String,
    /// RFC 3339
    pub date: Option<String>,
    pub notes: Option<String>,
    /// false: this installation cannot update itself (deb), the release has the package
    pub installable: bool,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CheckResult {
    pub current: String,
    pub available: Option<Available>,
}

/// Linux: only an AppImage replaces itself (the runtime sets APPIMAGE); a deb is updated
/// with the package manager. Windows: the NSIS setup.
pub fn installable(os: &str, appimage: Option<&str>) -> bool {
    match os {
        "linux" => appimage.is_some_and(|p| !p.is_empty()),
        _ => true,
    }
}

#[tauri::command]
async fn updater_check(app: AppHandle, pending: State<'_, Pending>) -> Result<CheckResult, String> {
    let current = app.package_info().version.to_string();
    let update = app.updater().map_err(|e| e.to_string())?.check().await.map_err(|e| e.to_string())?;
    let available = update.as_ref().map(|u| Available {
        version: u.version.clone(),
        date: u.date.and_then(|d| d.format(&time::format_description::well_known::Rfc3339).ok()),
        notes: u.body.clone(),
        installable: installable(std::env::consts::OS, std::env::var("APPIMAGE").ok().as_deref()),
    });
    *pending.0.lock().unwrap() = update;
    Ok(CheckResult { current, available })
}

/// downloads, checks the signature and installs the version the user agreed to, then
/// restarts; another version than the checked one (a newer release meanwhile) is refused
#[tauri::command]
async fn updater_install(app: AppHandle, pending: State<'_, Pending>, version: String) -> Result<(), String> {
    let update = pending.0.lock().unwrap().take();
    let Some(update) = update.filter(|u| u.version == version) else {
        return Err(format!("no checked update to {version}: check again"));
    };
    if !installable(std::env::consts::OS, std::env::var("APPIMAGE").ok().as_deref()) {
        return Err("this installation (deb) is updated with the package of the release".into());
    }
    update.download_and_install(|_, _| {}, || {}).await.map_err(|e| e.to_string())?;
    app.restart();
}

#[cfg(test)]
mod tests {
    use super::installable;

    #[test]
    fn installable_by_platform() {
        assert!(installable("windows", None));
        assert!(installable("linux", Some("/home/u/xvpn.AppImage")));
        assert!(!installable("linux", None));
        assert!(!installable("linux", Some("")));
    }
}
