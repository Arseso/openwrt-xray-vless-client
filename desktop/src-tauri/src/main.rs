// no console window next to the app on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    xvpn_lib::run()
}
