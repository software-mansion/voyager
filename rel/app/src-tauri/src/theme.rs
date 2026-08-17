use tauri::Emitter;
use tauri::Manager;

const OS_THEME_CHANGED: &str = "os-theme-changed";

/// Maps a Tauri window theme to `"dark"` / `"light"`.
///
/// tao maps portal `NoPreference` and detection failure to `Theme::Light`,
/// so Auto without a preference is light. Unknown `Theme` variants and a
/// failed `window.theme()` map to `None` — callers must not invent a theme.
fn from_tauri_theme(theme: tauri::Theme) -> Option<&'static str> {
    match theme {
        tauri::Theme::Dark => Some("dark"),
        tauri::Theme::Light => Some("light"),
        _ => None,
    }
}

fn appearance_str(theme: Option<tauri::Theme>) -> Option<&'static str> {
    from_tauri_theme(theme?)
}

/// Current OS appearance (`"dark"` / `"light"`), or `None` if detection failed.
#[tauri::command]
pub fn os_theme(window: tauri::WebviewWindow) -> Option<&'static str> {
    current(&window)
}

/// Current OS appearance for this window (`"dark"` / `"light"`), or `None`
/// if detection failed.
pub fn current(window: &tauri::WebviewWindow) -> Option<&'static str> {
    appearance_str(window.theme().ok())
}

/// Initialization script that seeds `window.__VOYAGER_OS_THEME__` before the
/// page head script runs. Only `"dark"` and `"light"` are injected.
pub fn seed_script(appearance: &str) -> Option<String> {
    match appearance {
        "dark" | "light" => Some(format!(
            r#"(function(){{window.__VOYAGER_OS_THEME__="{appearance}";}})();"#
        )),
        _ => None,
    }
}

/// Subscribe to OS appearance changes for this window and emit `os-theme-changed`.
pub fn listen(window: &tauri::WebviewWindow) {
    let app = window.app_handle().clone();
    window.on_window_event(move |event| {
        if let tauri::WindowEvent::ThemeChanged(theme) = event {
            if let Some(appearance) = from_tauri_theme(*theme) {
                let _ = app.emit(OS_THEME_CHANGED, appearance);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appearance_str_maps_dark_and_light() {
        assert_eq!(appearance_str(Some(tauri::Theme::Dark)), Some("dark"));
        assert_eq!(appearance_str(Some(tauri::Theme::Light)), Some("light"));
    }

    #[test]
    fn appearance_str_maps_detection_failure_to_none() {
        assert_eq!(appearance_str(None), None);
    }

    #[test]
    fn seed_script_injects_only_dark_and_light() {
        assert!(seed_script("dark").unwrap().contains(r#"="dark""#));
        assert!(seed_script("light").unwrap().contains(r#"="light""#));
        assert_eq!(seed_script("system"), None);
    }
}
