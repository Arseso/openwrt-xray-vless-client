//! System notifications (#80).
//!
//! Like the tray (tray.rs): the web view decides on its bus events what to notify
//! (src/core/notify.ts: VPN down/back, failover, router unreachable, subscription
//! expiring, quiet hours, one notification per event) and calls notify_show; this
//! module only shows it through tauri-plugin-notification.

use tauri::ipc::Invoke;
use tauri::{App, AppHandle, Wry};
use tauri_plugin_notification::NotificationExt;

use crate::error::{Result, TransportError};

pub fn init(app: &mut App) -> tauri::Result<()> {
    app.handle().plugin(tauri_plugin_notification::init())?;
    Ok(())
}

/// commands named notify_*; lib.rs routes them here
pub fn handler() -> impl Fn(Invoke<Wry>) -> bool + Send + Sync + 'static {
    tauri::generate_handler![notify_show]
}

/// title and body come from the router (server names): one line of plain text
fn plain(s: &str, max: usize) -> String {
    s.chars().filter(|c| !c.is_control()).take(max).collect()
}

/// the body of a freedesktop notification may be markup (GNOME, KDE): "a & b" or "<x>" in
/// a server name must stay text. Windows and macOS take it as text and would show "&amp;"
fn body_text(s: &str) -> String {
    if cfg!(all(unix, not(target_os = "macos"))) {
        s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
    } else {
        s.to_string()
    }
}

/// Ok once the notification is handed to the system: tauri-plugin-notification shows it on
/// a background task, a missing notification daemon (Linux) is only logged there
#[tauri::command]
fn notify_show(app: AppHandle, title: String, body: String) -> Result<()> {
    app.notification()
        .builder()
        .title(plain(&title, 120))
        .body(body_text(&plain(&body, 400)))
        .show()
        .map_err(|e| TransportError::new("notify", e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::{body_text, plain};

    #[test]
    fn plain_text_only() {
        assert_eq!(plain("a<b>c\nd", 100), "a<b>cd");
        assert_eq!(plain("сервер", 3), "сер");
    }

    #[test]
    #[cfg(all(unix, not(target_os = "macos")))]
    fn body_is_escaped_for_markup() {
        assert_eq!(body_text("A & B <x>"), "A &amp; B &lt;x&gt;");
    }
}
