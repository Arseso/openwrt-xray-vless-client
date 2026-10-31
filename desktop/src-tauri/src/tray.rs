//! Tray icon and its menu: TODO(#78).
//!
//! The state comes from the shared poller of the web view (src/core/poller.ts): the
//! web view calls tray_* commands of this module on its bus events (state-change,
//! router-down/up), the module owns the icon and the menu. The window may be hidden
//! to the tray, the poller keeps running in it.

use tauri::ipc::Invoke;
use tauri::{App, Wry};

pub fn init(_app: &mut App) -> tauri::Result<()> {
    // TODO(#78): TrayIconBuilder (tauri feature "tray-icon"), menu, close to tray
    Ok(())
}

/// commands named tray_*; lib.rs routes them here
pub fn handler() -> impl Fn(Invoke<Wry>) -> bool + Send + Sync + 'static {
    tauri::generate_handler![]
}
