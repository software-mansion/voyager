use std::ffi::{CStr, CString, c_char};
use std::sync::OnceLock;

use tauri::AppHandle;

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

pub struct Tray;

/// Adds the menu bar icon and its SwiftUI popover. Must run on the main thread.
pub fn setup(app: &tauri::App) -> tauri::Result<Tray> {
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

    Ok(Tray)
}

impl Tray {
    pub fn update(&self, status_json: &[u8]) {
        let Ok(status_json) = CString::new(status_json) else {
            return;
        };
        if let Some(app_handle) = APP_HANDLE.get() {
            let _ = app_handle
                .run_on_main_thread(move || unsafe { voyager_tray_update(status_json.as_ptr()) });
        }
    }
}

extern "C" fn on_action(action: *const c_char) {
    let action = unsafe { CStr::from_ptr(action) }.to_string_lossy();

    if let Some(app_handle) = APP_HANDLE.get() {
        crate::tray_action(app_handle, &action);
    }
}
