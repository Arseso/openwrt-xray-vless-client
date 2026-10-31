//! xvpn: remote control of luci-app-xvpn on an OpenWrt router. The web view (src/) does
//! the UI and the ubus logic; Rust does what a web view must not or cannot: HTTP(S)
//! with a pinned self-signed certificate, the passwords, the system integration.
//!
//! Modules: commands (core commands), transport + pin (HTTP, TOFU), profiles (routers,
//! keyring), gateway, tray (#78), notifications (#80). Each feature module brings its own
//! init() and handler(); commands are routed by name prefix, so a new command of the
//! tray or notifications does not touch this file.

mod commands;
mod error;
mod gateway;
mod notifications;
mod pin;
mod profiles;
mod transport;
mod tray;
mod vpncheck;

use std::sync::Arc;

use tauri::Manager;

pub fn run() {
    let core = commands::handler();
    let tray = tray::handler();
    let notify = notifications::handler();
    let vpn = vpncheck::handler();

    tauri::Builder::default()
        .setup(|app| {
            let dir = app.path().app_config_dir()?;
            app.manage(commands::Core { profiles: Arc::new(profiles::Profiles::load(dir)), http: Default::default() });
            tray::init(app)?;
            notifications::init(app)?;
            Ok(())
        })
        .invoke_handler(move |invoke| {
            let cmd = invoke.message.command();
            if cmd.starts_with("tray_") {
                tray(invoke)
            } else if cmd.starts_with("notify_") {
                notify(invoke)
            } else if cmd.starts_with("vpn_") {
                vpn(invoke)
            } else {
                core(invoke)
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running the app");
}
