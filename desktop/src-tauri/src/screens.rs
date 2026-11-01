//! Plugins of the tabs Subscriptions and Log (#79): the clipboard (import of a share link
//! or a subscription URL, copying the log) and the save dialog with a file write (export
//! of the diagnostics). The web view calls them directly; their permissions are in
//! capabilities/screens.json. The dialog adds the chosen path to the scope of the fs
//! plugin: the web view can write only the file the user picked.

use tauri::App;

pub fn init(app: &mut App) -> tauri::Result<()> {
    let handle = app.handle();
    handle.plugin(tauri_plugin_clipboard_manager::init())?;
    handle.plugin(tauri_plugin_dialog::init())?;
    handle.plugin(tauri_plugin_fs::init())?;
    Ok(())
}
