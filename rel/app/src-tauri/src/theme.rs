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
/// Linux reads the settings portal. macOS reads `AppleInterfaceStyle`.
/// Other desktops return `None` so the page may first-paint from `matchMedia`.
/// Native window fill is always dark until JS calls `set_surface`.
pub async fn snapshot() -> Option<&'static str> {
    #[cfg(target_os = "linux")]
    {
        portal_appearance().await
    }

    #[cfg(target_os = "macos")]
    {
        macos_appearance()
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        None
    }
}

/// Light mode omits `AppleInterfaceStyle`; Dark sets it to `Dark`.
#[cfg(target_os = "macos")]
fn macos_appearance() -> Option<&'static str> {
    let output = std::process::Command::new("defaults")
        .args(["read", "-g", "AppleInterfaceStyle"])
        .output()
        .ok()?;

    if output.status.success() {
        let value = String::from_utf8_lossy(&output.stdout);
        if value.trim().eq_ignore_ascii_case("dark") {
            Some("dark")
        } else {
            Some("light")
        }
    } else {
        Some("light")
    }
}

/// DaisyUI `--color-base-200` used by `html, body` (`assets/css/app.css`).
/// dark: oklch(23.26% 0.014 253.1); light: oklch(98% 0.003 247.858).
const BASE_200_DARK: tauri::window::Color = tauri::window::Color(32, 36, 41, 255);
const BASE_200_LIGHT: tauri::window::Color = tauri::window::Color(247, 248, 250, 255);

/// Native window/webview fill matching DaisyUI `base-200`.
pub fn surface_color(appearance: &str) -> Option<tauri::window::Color> {
    match appearance {
        "dark" => Some(BASE_200_DARK),
        "light" => Some(BASE_200_LIGHT),
        _ => None,
    }
}

/// Dark `base-200` used until JS knows the resolved theme is light.
pub fn default_surface() -> tauri::window::Color {
    BASE_200_DARK
}

/// Syncs the native window/webview fill to the resolved DaisyUI theme.
#[tauri::command]
pub fn set_surface(window: tauri::WebviewWindow, theme: String) {
    if let Some(color) = surface_color(&theme) {
        let _ = window.set_background_color(Some(color));
    }
}

/// Initialization script that sets `data-theme` and `__VOYAGER_OS_THEME__`
/// at document-start, before the page stylesheet.
///
/// OS: sessionStorage, then the create-time snapshot when present, then
/// matchMedia. Preference: localStorage `phx:theme`. Native `set_surface` is
/// left to the page script so we never paint light before `phx:theme` is
/// readable. Unknown preference stays dark.
pub fn seed_script(appearance: Option<&str>) -> String {
    let snapshot = match appearance {
        Some("dark") => "dark",
        Some("light") => "light",
        _ => "",
    };

    format!(
        r#"(function(){{
  var os;
  try {{
    var remembered = sessionStorage.getItem("voyager:os-theme");
    if (remembered === "dark" || remembered === "light") os = remembered;
  }} catch (e) {{}}
  if (!os && "{snapshot}") os = "{snapshot}";
  if (!os) os = window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  window.__VOYAGER_OS_THEME__ = os;
  var pref;
  try {{ pref = localStorage.getItem("phx:theme"); }} catch (e) {{}}
  var theme = "dark";
  if (pref === "light") theme = "light";
  else if (pref !== "dark" && os === "light") theme = "light";
  document.documentElement.setAttribute("data-theme", theme);
}})();"#
    )
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
    fn seed_script_sets_data_theme_and_prefers_session_storage() {
        let dark = seed_script(Some("dark"));
        assert!(dark.contains(r#"sessionStorage.getItem("voyager:os-theme")"#));
        assert!(dark.contains(r#"setAttribute("data-theme""#));
        assert!(dark.contains(r#"theme = "dark""#));
        assert!(!dark.contains("set_surface"));
        assert!(dark.contains(r#"os = "dark""#));

        let light = seed_script(Some("light"));
        assert!(light.contains(r#"sessionStorage.getItem("voyager:os-theme")"#));
        assert!(light.contains(r#"setAttribute("data-theme""#));
        assert!(light.contains(r#"os = "light""#));

        let none = seed_script(None);
        assert!(none.contains(r#"setAttribute("data-theme""#));
        assert!(none.contains("matchMedia"));
        assert!(!none.contains(r#"os = "dark""#));
        assert!(!none.contains(r#"os = "light""#));
    }

    #[test]
    fn surface_color_maps_dark_and_light() {
        assert_eq!(surface_color("dark"), Some(BASE_200_DARK));
        assert_eq!(surface_color("light"), Some(BASE_200_LIGHT));
        assert_eq!(surface_color("system"), None);
        assert_eq!(default_surface(), BASE_200_DARK);
    }
}
