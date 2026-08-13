use tauri::Emitter;
use tauri::Manager;

const OS_THEME_CHANGED: &str = "os-theme-changed";

#[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]
const PORTAL_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(300);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Detected {
    Dark,
    Light,
}

/// Maps a detected OS appearance. `None` means detection failed — callers
/// must not invent a theme.
fn appearance_str(detected: Option<Detected>) -> Option<&'static str> {
    match detected {
        Some(Detected::Dark) => Some("dark"),
        Some(Detected::Light) => Some("light"),
        None => None,
    }
}

#[cfg(not(all(unix, not(any(target_os = "macos", target_os = "ios")))))]
fn from_tauri_theme(theme: tauri::Theme) -> Option<Detected> {
    match theme {
        tauri::Theme::Dark => Some(Detected::Dark),
        tauri::Theme::Light => Some(Detected::Light),
        _ => None,
    }
}

/// Current OS appearance (`"dark"` / `"light"`), or `None` if detection failed.
#[tauri::command]
pub async fn os_theme(window: tauri::WebviewWindow) -> Option<&'static str> {
    current(&window).await
}

/// Subscribe to OS appearance changes for this window and emit `os-theme-changed`.
pub fn listen(window: &tauri::WebviewWindow) {
    #[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]
    listen_portal(window.app_handle().clone());

    #[cfg(not(all(unix, not(any(target_os = "macos", target_os = "ios")))))]
    listen_window(window);
}

async fn current(window: &tauri::WebviewWindow) -> Option<&'static str> {
    #[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]
    {
        let _ = window;
        appearance_str(portal_detect().await)
    }

    #[cfg(not(all(unix, not(any(target_os = "macos", target_os = "ios")))))]
    {
        appearance_str(from_tauri_theme(window.theme().ok()?))
    }
}

fn emit_appearance(app: &tauri::AppHandle, detected: Option<Detected>) {
    if let Some(theme) = appearance_str(detected) {
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
fn from_portal(scheme: ashpd::desktop::settings::ColorScheme) -> Detected {
    use ashpd::desktop::settings::ColorScheme;

    match scheme {
        ColorScheme::PreferDark => Detected::Dark,
        ColorScheme::PreferLight | ColorScheme::NoPreference => Detected::Light,
    }
}

#[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]
async fn portal_detect() -> Option<Detected> {
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
        assert_eq!(appearance_str(Some(Detected::Dark)), Some("dark"));
        assert_eq!(appearance_str(Some(Detected::Light)), Some("light"));
    }

    #[test]
    fn appearance_str_maps_detection_failure_to_none() {
        assert_eq!(appearance_str(None), None);
    }
}
