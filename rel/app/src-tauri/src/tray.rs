use std::ffi::{CStr, CString, c_char};
use std::sync::OnceLock;

use tauri::{AppHandle, Manager};

pub const TOPIC: &str = "tray";
const DISCONNECT_ID: &str = "disconnect";
const TOGGLE_MCP_ID: &str = "toggle_mcp";
const OPEN_ID: &str = "open";
const QUIT_ID: &str = "quit";

// Implemented in swift/VoyagerTray, linked by build.rs.
unsafe extern "C" {
    fn voyager_tray_setup(
        icon: *const u8,
        icon_len: isize,
        version: *const c_char,
        on_action: extern "C" fn(*const c_char),
    );
    fn voyager_tray_update(status_json: *const c_char);
}

static APP_HANDLE: OnceLock<AppHandle> = OnceLock::new();

/// Adds the menu bar icon and its SwiftUI popover. Must run on the main thread.
pub fn setup(app: &tauri::App) {
    let icon = include_bytes!("../icons/tray.png");
    let version = CString::new(app.package_info().version.to_string()).unwrap_or_default();
    let _ = APP_HANDLE.set(app.handle().clone());

    unsafe {
        voyager_tray_setup(
            icon.as_ptr(),
            icon.len() as isize,
            version.as_ptr(),
            on_action,
        )
    };
}

pub fn update(status_json: &[u8]) {
    let Ok(status_json) = CString::new(status_json) else {
        return;
    };
    if let Some(app_handle) = APP_HANDLE.get() {
        let _ = app_handle
            .run_on_main_thread(move || unsafe { voyager_tray_update(status_json.as_ptr()) });
    }
}

/// Window actions stay in Rust, the rest go to Elixir.
extern "C" fn on_action(action: *const c_char) {
    let action = unsafe { CStr::from_ptr(action) }.to_string_lossy();
    let Some(app_handle) = APP_HANDLE.get() else {
        return;
    };

    match action.as_ref() {
        OPEN_ID => crate::open_window(app_handle),
        QUIT_ID => app_handle.exit(0),
        DISCONNECT_ID | TOGGLE_MCP_ID => {
            let _ = app_handle
                .state::<elixirkit::PubSub>()
                .broadcast(TOPIC, action.as_bytes());
        }
        _ => {}
    }
}
