//! System notifications: TODO(#80).
//!
//! Like the tray (tray.rs): the web view decides on its bus events what to notify
//! (VPN down/back, failover, router unreachable, subscription expiring) and calls the
//! notify_* commands of this module, or tauri-plugin-notification directly.

use tauri::ipc::Invoke;
use tauri::{App, Wry};

pub fn init(_app: &mut App) -> tauri::Result<()> {
    // TODO(#80): tauri-plugin-notification, quiet hours
    Ok(())
}

/// commands named notify_*; lib.rs routes them here
pub fn handler() -> impl Fn(Invoke<Wry>) -> bool + Send + Sync + 'static {
    tauri::generate_handler![]
}
