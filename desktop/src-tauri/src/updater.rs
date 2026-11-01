//! Updates of the app (#81): tauri-plugin-updater against latest.json of the latest GitHub
//! release (the endpoint and the public key are in tauri.conf.json, plugins.updater).
//! Nothing happens by itself: the web view asks with updater_check (a button) and shows
//! what is there; updater_install asks the user itself, in a native dialog with its own
//! text, so no script in the web view can install without them. The signature of the
//! package is checked by the plugin against the public key before anything is installed.
//!
//! The plugin's own JS API is not granted to the web view (no capability for it): these
//! two commands are all it can do. Installable: the NSIS setup on Windows, the AppImage and
//! the deb (the plugin runs dpkg through pkexec) on Linux; another installation (an MSI
//! built by hand, an rpm, a bare binary) is told to take the package of the release.

use std::sync::Mutex;

use serde::Serialize;
use tauri::ipc::Invoke;
use tauri::utils::config::BundleType;
use tauri::utils::platform::bundle_type;
use tauri::{App, AppHandle, Manager, State, Wry};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};
use tauri_plugin_updater::{Update, UpdaterExt};

/// the update found by the last check, kept for updater_install
#[derive(Default)]
struct Pending(Mutex<Option<Update>>);

pub fn init(app: &mut App) -> tauri::Result<()> {
    app.handle().plugin(tauri_plugin_updater::Builder::new().build())?;
    app.handle().plugin(tauri_plugin_dialog::init())?;
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
    /// false: this installation cannot update itself, the release has the package
    pub installable: bool,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CheckResult {
    pub current: String,
    pub available: Option<Available>,
}

/// what the plugin can replace: the bundle the running binary came from (the bundler
/// patches it into the binary); latest.json has the AppImage, the deb and the NSIS setup
pub fn installable(os: &str, bundle: Option<BundleType>) -> bool {
    match os {
        "linux" => matches!(bundle, Some(BundleType::AppImage) | Some(BundleType::Deb)),
        "windows" => !matches!(bundle, Some(BundleType::Msi)),
        _ => false,
    }
}

fn here_installable() -> bool {
    installable(std::env::consts::OS, bundle_type())
}

/// the question of the native dialog; lang only picks the language of the app
pub fn question(lang: &str, version: &str) -> (String, &'static str, &'static str) {
    if lang == "ru" {
        (format!("Скачать xvpn {version}, установить и перезапустить приложение?"), "Установить", "Отмена")
    } else {
        (format!("Download xvpn {version}, install it and restart the app?"), "Install", "Cancel")
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
        installable: here_installable(),
    });
    *pending.0.lock().unwrap() = update;
    Ok(CheckResult { current, available })
}

/// asks the user (native dialog), then downloads, checks the signature and installs the
/// version the last check found and restarts; another version than the checked one (a
/// newer release meanwhile) is refused. Err("cancelled"): the user said no.
#[tauri::command]
async fn updater_install(app: AppHandle, pending: State<'_, Pending>, version: String, lang: String) -> Result<(), String> {
    if !here_installable() {
        return Err("this installation is updated with the package of the release".into());
    }
    let update = pending.0.lock().unwrap().take();
    let Some(update) = update.filter(|u| u.version == version) else {
        return Err(format!("no checked update to {version}: check again"));
    };
    let (text, yes, no) = question(&lang, &update.version);
    let dialog = app.clone();
    let agreed = tauri::async_runtime::spawn_blocking(move || {
        dialog
            .dialog()
            .message(text)
            .title("xvpn")
            .kind(MessageDialogKind::Info)
            .buttons(MessageDialogButtons::OkCancelCustom(yes.into(), no.into()))
            .blocking_show()
    })
    .await
    .map_err(|e| e.to_string())?;
    if !agreed {
        // the same update may be installed after all: the next press asks again
        *pending.0.lock().unwrap() = Some(update);
        return Err("cancelled".into());
    }
    update.download_and_install(|_, _| {}, || {}).await.map_err(|e| e.to_string())?;
    app.restart();
}

#[cfg(test)]
mod tests {
    use super::{installable, question};
    use tauri::utils::config::BundleType;

    #[test]
    fn installable_by_bundle() {
        assert!(installable("windows", Some(BundleType::Nsis)));
        assert!(installable("windows", None));
        assert!(!installable("windows", Some(BundleType::Msi)));
        assert!(installable("linux", Some(BundleType::AppImage)));
        assert!(installable("linux", Some(BundleType::Deb)));
        assert!(!installable("linux", Some(BundleType::Rpm)));
        assert!(!installable("linux", None));
        assert!(!installable("macos", Some(BundleType::Dmg)));
    }

    #[test]
    fn question_by_language() {
        assert_eq!(question("ru", "0.2.0").1, "Установить");
        let (text, yes, no) = question("en", "0.2.0");
        assert!(text.contains("0.2.0"));
        assert_eq!((yes, no), ("Install", "Cancel"));
        assert_eq!(question("de", "1").1, "Install");
    }
}
