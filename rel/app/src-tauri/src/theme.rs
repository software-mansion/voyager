use tauri::Emitter;
use tauri::Manager;

const OS_THEME_CHANGED: &str = "os-theme-changed";

#[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]
const PORTAL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// Maps a Tauri window theme to `"dark"` / `"light"`.
///
/// tao maps portal `NoPreference` and detection failure to `Theme::Light`,
/// so Auto without a preference is light. Unknown `Theme` variants and a
/// failed `window.theme()` map to `None` — callers must not invent a theme.
///
/// On Linux, `window.theme()` is cached at window creation and
/// `ThemeChanged` is emitted for a dummy window id that Tauri drops, so
/// live OS appearance must not use this path.
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
pub async fn os_theme(window: tauri::WebviewWindow) -> Option<&'static str> {
    #[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]
    {
        let _ = window;
        portal_appearance().await
    }

    #[cfg(not(all(unix, not(any(target_os = "macos", target_os = "ios")))))]
    {
        current(&window)
    }
}

/// Cached window theme. Correct at create time; stale after OS changes on Linux.
pub fn current(window: &tauri::WebviewWindow) -> Option<&'static str> {
    appearance_str(window.theme().ok())
}

/// Create-time OS appearance for the window init script.
///
/// Linux reads the settings portal (same source as live updates). Other
/// desktops return `None` so the page may first-paint from `matchMedia`.
pub async fn snapshot() -> Option<&'static str> {
    #[cfg(target_os = "linux")]
    {
        portal_appearance().await
    }

    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

/// Initialization script that seeds `window.__VOYAGER_OS_THEME__` before the
/// page head script runs. Prefers a live `sessionStorage` value on reload,
/// then the create-time snapshot. Only `"dark"` and `"light"` are injected.
pub fn seed_script(appearance: &str) -> Option<String> {
    match appearance {
        "dark" | "light" => Some(format!(
            r#"(function(){{
  try {{
    var remembered = sessionStorage.getItem("voyager:os-theme");
    if (remembered === "dark" || remembered === "light") {{
      window.__VOYAGER_OS_THEME__ = remembered;
      return;
    }}
  }} catch (e) {{}}
  window.__VOYAGER_OS_THEME__ = "{appearance}";
}})();"#
        )),
        _ => None,
    }
}

/// Subscribe to OS appearance changes and emit `os-theme-changed`.
pub fn listen(window: &tauri::WebviewWindow) {
    #[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]
    listen_portal(window.app_handle().clone());

    #[cfg(not(all(unix, not(any(target_os = "macos", target_os = "ios")))))]
    listen_window(window);
}

fn emit_appearance(app: &tauri::AppHandle, appearance: Option<&'static str>) {
    if let Some(theme) = appearance {
        let _ = app.emit(OS_THEME_CHANGED, theme);
    }
}

#[cfg(not(all(unix, not(any(target_os = "macos", target_os = "ios")))))]
fn listen_window(window: &tauri::WebviewWindow) {
    let app = window.app_handle().clone();
    window.on_window_event(move |event| {
        if let tauri::WindowEvent::ThemeChanged(theme) = event {
            emit_appearance(&app, from_tauri_theme(*theme));
        }
    });
}

#[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]
fn from_portal(scheme: ashpd::desktop::settings::ColorScheme) -> &'static str {
    use ashpd::desktop::settings::ColorScheme;

    match scheme {
        ColorScheme::PreferDark => "dark",
        ColorScheme::PreferLight | ColorScheme::NoPreference => "light",
    }
}

#[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]
async fn portal_appearance() -> Option<&'static str> {
    use ashpd::desktop::settings::Settings;

    tokio::time::timeout(PORTAL_TIMEOUT, async {
        let settings = Settings::new().await.ok()?;
        let scheme = settings.color_scheme().await.ok()?;
        Some(from_portal(scheme))
    })
    .await
    .ok()
    .flatten()
}

#[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]
fn listen_portal(app: tauri::AppHandle) {
    use std::sync::atomic::AtomicBool;
    use std::sync::atomic::Ordering;

    static STARTED: AtomicBool = AtomicBool::new(false);
    if STARTED.swap(true, Ordering::SeqCst) {
        return;
    }

    tauri::async_runtime::spawn(async move {
        use ashpd::desktop::settings::Settings;
        use futures_util::StreamExt;

        let Ok(settings) = Settings::new().await else {
            return;
        };

        if let Ok(scheme) = settings.color_scheme().await {
            emit_appearance(&app, Some(from_portal(scheme)));
        }

        let Ok(mut stream) = settings.receive_color_scheme_changed().await else {
            return;
        };

        while let Some(scheme) = stream.next().await {
            emit_appearance(&app, Some(from_portal(scheme)));
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
        let dark = seed_script("dark").unwrap();
        assert!(dark.contains(r#"sessionStorage.getItem("voyager:os-theme")"#));
        assert!(dark.contains(r#"window.__VOYAGER_OS_THEME__ = "dark""#));
        let light = seed_script("light").unwrap();
        assert!(light.contains(r#"sessionStorage.getItem("voyager:os-theme")"#));
        assert!(light.contains(r#"window.__VOYAGER_OS_THEME__ = "light""#));
        assert_eq!(seed_script("system"), None);
    }
}
