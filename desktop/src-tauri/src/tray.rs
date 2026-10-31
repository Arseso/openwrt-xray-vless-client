//! Tray icon and its menu (#78), autostart, closing the window to the tray.
//!
//! The web view computes what to show (src/tray/model.ts) on every poll and sends it
//! with tray_update; this module only puts it on the screen: the icon, the hover text
//! and the menu (texts changed in place, the menu rebuilt only when its shape changes:
//! other servers, another language). Clicks go back as the event tray-action
//! (src/tray/index.ts), except Open window, Open LuCI and Quit, done here.

use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use tauri::image::Image;
use tauri::ipc::Invoke;
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{App, AppHandle, Emitter, Manager, State, WindowEvent, Wry};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

/// the argument autostart passes: start hidden in the tray
const MINIMIZED: &str = "--minimized";

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrayServer {
    id: String,
    label: String,
    active: bool,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Labels {
    server: String,
    auto: String,
    test: String,
    service: String,
    start: String,
    stop: String,
    restart: String,
    open: String,
    luci: String,
    quit: String,
}

/// src/tray/model.ts TrayModel
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrayModel {
    icon: String,
    tooltip: String,
    info: Vec<String>,
    servers: Vec<TrayServer>,
    auto: Option<bool>,
    online: bool,
    luci_url: Option<String>,
    labels: Labels,
}

impl Default for TrayModel {
    fn default() -> Self {
        let l = |s: &str| s.to_string();
        TrayModel {
            icon: "offline".into(),
            tooltip: "xvpn".into(),
            info: vec![l("xvpn")],
            servers: vec![],
            auto: None,
            online: false,
            luci_url: None,
            labels: Labels {
                server: l("Server"),
                auto: l("Auto selection"),
                test: l("Test all"),
                service: l("Service"),
                start: l("Start"),
                stop: l("Stop"),
                restart: l("Restart"),
                open: l("Open window"),
                luci: l("Open LuCI"),
                quit: l("Quit"),
            },
        }
    }
}

/// what makes another menu necessary; anything else is changed in place
fn shape(m: &TrayModel) -> (usize, Vec<String>, &Labels) {
    (m.info.len(), m.servers.iter().map(|s| s.id.clone()).collect(), &m.labels)
}

struct Items {
    info: Vec<MenuItem<Wry>>,
    server_menu: Submenu<Wry>,
    servers: Vec<CheckMenuItem<Wry>>,
    auto: CheckMenuItem<Wry>,
    test: MenuItem<Wry>,
    service: Submenu<Wry>,
}

struct TrayState {
    icon: TrayIcon<Wry>,
    model: TrayModel,
    items: Items,
}

#[derive(Default)]
pub struct Tray(Mutex<Option<TrayState>>);

/// the event tray-action of src/tray/index.ts
#[derive(Clone, Serialize)]
#[serde(tag = "action", rename_all = "lowercase")]
enum Action {
    Select { id: String },
    Auto { value: bool },
    Test,
    Service { value: &'static str },
    Refresh,
}

fn icon(name: &str) -> Image<'static> {
    let bytes: &'static [u8] = match name {
        "connected" => include_bytes!("../icons/tray/connected.png"),
        "failover" => include_bytes!("../icons/tray/failover.png"),
        "wan_down" => include_bytes!("../icons/tray/wan_down.png"),
        "xray_down" => include_bytes!("../icons/tray/xray_down.png"),
        "stopped" => include_bytes!("../icons/tray/stopped.png"),
        _ => include_bytes!("../icons/tray/offline.png"),
    };
    Image::from_bytes(bytes).expect("tray icon")
}

fn build(app: &AppHandle, m: &TrayModel) -> tauri::Result<(Menu<Wry>, Items)> {
    let l = &m.labels;
    let info = m
        .info
        .iter()
        .enumerate()
        .map(|(i, text)| MenuItem::with_id(app, format!("info:{i}"), text, false, None::<&str>))
        .collect::<tauri::Result<Vec<_>>>()?;
    let servers = m
        .servers
        .iter()
        .map(|s| CheckMenuItem::with_id(app, format!("srv:{}", s.id), &s.label, m.online, s.active, None::<&str>))
        .collect::<tauri::Result<Vec<_>>>()?;
    let refs: Vec<&dyn IsMenuItem<Wry>> = servers.iter().map(|s| s as &dyn IsMenuItem<Wry>).collect();
    let server_menu = Submenu::with_id_and_items(app, "servers", &l.server, m.online && !servers.is_empty(), &refs)?;
    let auto = CheckMenuItem::with_id(app, "auto", &l.auto, m.online && m.auto.is_some(), m.auto.unwrap_or(false), None::<&str>)?;
    let test = MenuItem::with_id(app, "test", &l.test, m.online, None::<&str>)?;
    let service = Submenu::with_id_and_items(
        app,
        "service",
        &l.service,
        m.online,
        &[
            &MenuItem::with_id(app, "svc:start", &l.start, true, None::<&str>)?,
            &MenuItem::with_id(app, "svc:stop", &l.stop, true, None::<&str>)?,
            &MenuItem::with_id(app, "svc:restart", &l.restart, true, None::<&str>)?,
        ],
    )?;
    let open = MenuItem::with_id(app, "open", &l.open, true, None::<&str>)?;
    let luci = MenuItem::with_id(app, "luci", &l.luci, m.luci_url.is_some(), None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", &l.quit, true, None::<&str>)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;

    let mut all: Vec<&dyn IsMenuItem<Wry>> = info.iter().map(|i| i as &dyn IsMenuItem<Wry>).collect();
    all.extend([&sep1 as &dyn IsMenuItem<Wry>, &server_menu, &auto, &test, &service, &sep2, &open, &luci, &quit]);
    let menu = Menu::with_items(app, &all)?;
    Ok((menu, Items { info, server_menu, servers, auto, test, service }))
}

/// the texts and states of a menu of the same shape
fn refresh(items: &Items, m: &TrayModel) -> tauri::Result<()> {
    for (item, text) in items.info.iter().zip(&m.info) {
        item.set_text(text)?;
    }
    for (item, s) in items.servers.iter().zip(&m.servers) {
        item.set_text(&s.label)?;
        item.set_checked(s.active)?;
        item.set_enabled(m.online)?;
    }
    items.server_menu.set_enabled(m.online && !items.servers.is_empty())?;
    items.auto.set_checked(m.auto.unwrap_or(false))?;
    items.auto.set_enabled(m.online && m.auto.is_some())?;
    items.test.set_enabled(m.online)?;
    items.service.set_enabled(m.online)?;
    Ok(())
}

fn show_window(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn open_url(url: &str) {
    #[cfg(windows)]
    let r = {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        std::process::Command::new("rundll32")
            .args(["url.dll,FileProtocolHandler", url])
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
    };
    #[cfg(not(windows))]
    let r = std::process::Command::new("xdg-open").arg(url).spawn();
    if let Err(e) = r {
        eprintln!("xvpn: cannot open {url}: {e}");
    }
}

fn on_menu(app: &AppHandle, event: MenuEvent) {
    let id = event.id().as_ref();
    let emit = |a: Action| {
        let _ = app.emit("tray-action", a);
    };
    match id {
        "open" => show_window(app),
        "quit" => app.exit(0),
        "luci" => {
            let url = app.state::<Tray>().0.lock().unwrap().as_ref().and_then(|t| t.model.luci_url.clone());
            if let Some(url) = url {
                open_url(&url);
            }
        }
        "test" => emit(Action::Test),
        "auto" => {
            // a check item toggles itself on click: its new state is the wish
            let value = app.state::<Tray>().0.lock().unwrap().as_ref().map(|t| t.items.auto.is_checked().unwrap_or(false));
            if let Some(value) = value {
                emit(Action::Auto { value });
            }
        }
        "svc:start" => emit(Action::Service { value: "start" }),
        "svc:stop" => emit(Action::Service { value: "stop" }),
        "svc:restart" => emit(Action::Service { value: "restart" }),
        // "… and N more": the full list is in the window
        "srv:" => show_window(app),
        _ => {
            if let Some(sid) = id.strip_prefix("srv:") {
                emit(Action::Select { id: sid.to_string() });
            }
        }
    }
}

/// whether something shows tray icons: on Linux a StatusNotifierItem host (GNOME has
/// none without the AppIndicator extension); elsewhere always
#[cfg(target_os = "linux")]
fn tray_host() -> bool {
    use dbus::blocking::Connection;
    use std::time::Duration;
    let Ok(conn) = Connection::new_session() else { return false };
    let proxy = conn.with_proxy("org.freedesktop.DBus", "/org/freedesktop/DBus", Duration::from_millis(500));
    let r: Result<(bool,), _> = proxy.method_call("org.freedesktop.DBus", "NameHasOwner", ("org.kde.StatusNotifierWatcher",));
    r.map(|(b,)| b).unwrap_or(false)
}

#[cfg(not(target_os = "linux"))]
fn tray_host() -> bool {
    true
}

pub fn init(app: &mut App) -> tauri::Result<()> {
    app.handle().plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, Some(vec![MINIMIZED])))?;
    app.manage(Tray::default());

    let handle = app.handle().clone();
    let model = TrayModel::default();
    let (menu, items) = build(&handle, &model)?;
    let tray = TrayIconBuilder::with_id("main")
        .icon(icon(&model.icon))
        .tooltip(&model.tooltip)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(on_menu)
        .on_tray_icon_event(|tray, event| match event {
            TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } => show_window(tray.app_handle()),
            // Windows: the menu opens on this click, the web view polls at once
            TrayIconEvent::Click { button: MouseButton::Right, button_state: MouseButtonState::Down, .. } => {
                let _ = tray.app_handle().emit("tray-action", Action::Refresh);
            }
            _ => {}
        })
        .build(app)?;
    *app.state::<Tray>().0.lock().unwrap() = Some(TrayState { icon: tray, model, items });

    // closing the window hides it to the tray; without a tray it only minimizes, the
    // app would be unreachable otherwise
    let host = tray_host();
    if let Some(w) = app.get_webview_window("main") {
        let win = w.clone();
        w.on_window_event(move |e| {
            if let WindowEvent::CloseRequested { api, .. } = e {
                api.prevent_close();
                let _ = if host { win.hide() } else { win.minimize() };
            }
        });
        if std::env::args().any(|a| a == MINIMIZED) {
            let _ = if host { w.hide() } else { w.minimize() };
        }
    }
    Ok(())
}

#[tauri::command]
fn tray_update(app: AppHandle, tray: State<'_, Tray>, model: TrayModel) -> Result<(), String> {
    let mut guard = tray.0.lock().unwrap();
    let Some(t) = guard.as_mut() else { return Ok(()) };
    if t.model == model {
        return Ok(());
    }
    let e = |e: tauri::Error| e.to_string();
    if t.model.icon != model.icon {
        t.icon.set_icon(Some(icon(&model.icon))).map_err(e)?;
    }
    if t.model.tooltip != model.tooltip {
        t.icon.set_tooltip(Some(&model.tooltip)).map_err(e)?;
    }
    if shape(&t.model) == shape(&model) {
        refresh(&t.items, &model).map_err(e)?;
    } else {
        let (menu, items) = build(&app, &model).map_err(e)?;
        t.icon.set_menu(Some(menu)).map_err(e)?;
        t.items = items;
    }
    t.model = model;
    Ok(())
}

#[tauri::command]
fn tray_autostart_get(app: AppHandle) -> Result<bool, String> {
    app.autolaunch().is_enabled().map_err(|e| e.to_string())
}

#[tauri::command]
fn tray_autostart_set(app: AppHandle, enabled: bool) -> Result<(), String> {
    let l = app.autolaunch();
    if enabled { l.enable() } else { l.disable() }.map_err(|e| e.to_string())
}

/// commands named tray_*; lib.rs routes them here
pub fn handler() -> impl Fn(Invoke<Wry>) -> bool + Send + Sync + 'static {
    tauri::generate_handler![tray_update, tray_autostart_get, tray_autostart_set]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icons_load() {
        for n in ["connected", "failover", "wan_down", "xray_down", "offline", "stopped", "unknown"] {
            assert_eq!(icon(n).width(), 64, "{n}");
        }
    }

    #[test]
    fn model_from_the_web_view() {
        let json = serde_json::json!({
            "icon": "connected", "tooltip": "xvpn", "info": ["● ok", "Server: A"],
            "servers": [{ "id": "a", "label": "A · 40 ms", "active": true }],
            "auto": true, "online": true, "luciUrl": "http://192.168.1.1/cgi-bin/luci",
            "labels": { "server": "S", "auto": "A", "test": "T", "service": "Sv", "start": "1", "stop": "2",
                        "restart": "3", "open": "O", "luci": "L", "quit": "Q" }
        });
        let m: TrayModel = serde_json::from_value(json).unwrap();
        assert_eq!(m.servers[0].id, "a");
        assert_eq!(m.luci_url.as_deref(), Some("http://192.168.1.1/cgi-bin/luci"));
        let mut other = m.clone();
        other.info[1] = "Server: B".into();
        assert_eq!(shape(&m), shape(&other));
        other.servers.push(TrayServer { id: "b".into(), label: "B".into(), active: false });
        assert_ne!(shape(&m), shape(&other));
    }

    #[test]
    fn actions_as_the_web_view_reads_them() {
        let j = |a: Action| serde_json::to_value(a).unwrap();
        assert_eq!(j(Action::Select { id: "x".into() }), serde_json::json!({ "action": "select", "id": "x" }));
        assert_eq!(j(Action::Auto { value: false }), serde_json::json!({ "action": "auto", "value": false }));
        assert_eq!(j(Action::Service { value: "restart" }), serde_json::json!({ "action": "service", "value": "restart" }));
        assert_eq!(j(Action::Refresh), serde_json::json!({ "action": "refresh" }));
    }
}
