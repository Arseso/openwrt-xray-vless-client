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

/// title and body come from the router (server names): plain text for the notification
/// daemon, which may take markup, so the angle brackets go
fn plain(s: &str, max: usize) -> String {
    s.chars().filter(|c| !c.is_control() && *c != '<' && *c != '>').take(max).collect()
}

#[tauri::command]
fn notify_show(app: AppHandle, title: String, body: String) -> Result<()> {
    app.notification()
        .builder()
        .title(plain(&title, 120))
        .body(plain(&body, 400))
        .show()
        .map_err(|e| TransportError::new("notify", e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::plain;

    #[test]
    fn plain_text_only() {
        assert_eq!(plain("a<b>c\nd", 100), "abcd");
        assert_eq!(plain("сервер", 3), "сер");
    }
}
