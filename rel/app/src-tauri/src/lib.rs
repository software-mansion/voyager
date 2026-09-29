mod utils;

use std::sync::Mutex;
use std::time::Duration;

use tauri::{
    Manager,
    menu::{HELP_SUBMENU_ID, MenuItemBuilder, PredefinedMenuItem},
};
use tauri_plugin_opener::OpenerExt;
use tauri_plugin_updater::{Update, UpdaterExt};

const MAIN_WINDOW_LABEL: &str = "main";
const REPORT_ISSUE_ID: &str = "report_issue";
const REPORT_ISSUE_URL: &str = "https://github.com/software-mansion/voyager/issues/new/choose";
const ZOOM_IN_ID: &str = "zoom_in";
const ZOOM_OUT_ID: &str = "zoom_out";
const ZOOM_RESET_ID: &str = "zoom_reset";
const DEFAULT_ZOOM: f64 = 1.0;
const ZOOM_STEP: f64 = 0.1;
const MIN_ZOOM: f64 = 0.5;
const MAX_ZOOM: f64 = 2.0;
const UPDATES_TOPIC: &str = "updates";
const UPDATE_STALL_TIMEOUT: Duration = Duration::from_secs(30);

/// Current zoom factor, since the webview does not expose a getter.
struct ZoomLevel(Mutex<f64>);

/// Update found at startup, installed when the user asks for it from the UI.
struct PendingUpdate(Mutex<Option<Update>>);

/// Current OS appearance for Auto theme after full page reloads.
#[tauri::command]
fn os_theme() -> &'static str {
    utils::os_theme_hint()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // Must be registered first so a second launch exits before Elixir starts.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            focus_existing_window(app);
        }))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(tauri::generate_handler![os_theme])
        .manage(ZoomLevel(Mutex::new(DEFAULT_ZOOM)))
        .manage(PendingUpdate(Mutex::new(None)))
        .on_menu_event(|app, event| match event.id().as_ref() {
            ZOOM_IN_ID => zoom_by(app, ZOOM_STEP),
            ZOOM_OUT_ID => zoom_by(app, -ZOOM_STEP),
            ZOOM_RESET_ID => zoom_to(app, DEFAULT_ZOOM),
            REPORT_ISSUE_ID => {
                let _ = app.opener().open_url(REPORT_ISSUE_URL, None::<&str>);
            }
            _ => {}
        })
        .setup(move |app| {
            #[cfg(target_os = "macos")]
            if let Some(menu) = app.menu() {
                // The default View submenu has no public id, unlike Help.
                let view_menu = menu
                    .items()?
                    .into_iter()
                    .filter_map(|item| item.as_submenu().cloned())
                    .find(|submenu| submenu.text().ok().as_deref() == Some("View"));

                if let Some(view_menu) = view_menu {
                    view_menu.prepend_items(&[
                        &MenuItemBuilder::with_id(ZOOM_RESET_ID, "Actual Size")
                            .accelerator("CmdOrCtrl+0")
                            .build(app)?,
                        &MenuItemBuilder::with_id(ZOOM_IN_ID, "Zoom In")
                            .accelerator("CmdOrCtrl+=")
                            .build(app)?,
                        &MenuItemBuilder::with_id(ZOOM_OUT_ID, "Zoom Out")
                            .accelerator("CmdOrCtrl+-")
                            .build(app)?,
                        &PredefinedMenuItem::separator(app)?,
                    ])?;
                }

                if let Some(help_menu) = menu
                    .get(HELP_SUBMENU_ID)
                    .and_then(|item| item.as_submenu().cloned())
                {
                    help_menu.append(
                        &MenuItemBuilder::with_id(REPORT_ISSUE_ID, "Report an Issue…")
                            .build(app)?,
                    )?;
                }
            }

            let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0").expect("failed to listen");

            let app_handle = app.handle().clone();
            let port =
                utils::available_port(4005).expect("failed to find available localhost port");
            let updates_pubsub = pubsub.clone();

            pubsub.subscribe("messages", move |msg| {
                if msg == b"ready" {
                    create_window(&app_handle, port);
                    // Debug builds run `mix phx.server` from the repo, there is no bundle to replace.
                    if !cfg!(debug_assertions) {
                        check_for_update(app_handle.clone(), updates_pubsub.clone());
                    }
                } else {
                    println!("[rust] {}", String::from_utf8_lossy(msg));
                }
            });

            let app_handle = app.handle().clone();
            let updates_pubsub = pubsub.clone();

            pubsub.subscribe(UPDATES_TOPIC, move |msg| match msg {
                b"install" => install_update(app_handle.clone(), updates_pubsub.clone()),
                b"check" => check_for_update(app_handle.clone(), updates_pubsub.clone()),
                _ => {}
            });

            let app_handle = app.handle().clone();

            tauri::async_runtime::spawn_blocking(move || {
                let rel_dir = app_handle.path().resource_dir().unwrap().join("rel");
                let data_dir = app_handle
                    .path()
                    .app_data_dir()
                    .expect("failed to resolve app data directory");

                std::fs::create_dir_all(&data_dir).expect("failed to create app data directory");

                let mut command = elixir_command(&rel_dir, &data_dir, port);
                command.env("ELIXIRKIT_PUBSUB", pubsub.url());
                let status = command.status().expect("failed to start Elixir");

                app_handle.exit(status.code().unwrap_or(1));
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn focus_existing_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        // Wayland often ignores set_focus but still reports Ok. No-op if already focused.
        let _ = window.request_user_attention(Some(tauri::UserAttentionType::Informational));
    }
}

fn check_for_update(app_handle: tauri::AppHandle, pubsub: elixirkit::PubSub) {
    tauri::async_runtime::spawn(async move {
        // The plugin sets no timeout, so a stalled download would never report `failed`.
        // A read timeout, unlike a total one, leaves slow but progressing downloads alone.
        let updater = app_handle
            .updater_builder()
            .configure_client(|client| {
                client
                    .connect_timeout(UPDATE_STALL_TIMEOUT)
                    .read_timeout(UPDATE_STALL_TIMEOUT)
            })
            .build();

        let update = match updater {
            Ok(updater) => updater.check().await,
            Err(error) => Err(error),
        };

        match update {
            Ok(Some(update)) => {
                let message = format!("available:{}", update.version);
                *app_handle.state::<PendingUpdate>().0.lock().unwrap() = Some(update);
                let _ = pubsub.broadcast(UPDATES_TOPIC, message.as_bytes());
            }
            Ok(None) => {
                let _ = pubsub.broadcast(UPDATES_TOPIC, b"none");
            }
            Err(error) => {
                eprintln!("[rust] update check failed: {error}");
                let _ = pubsub.broadcast(UPDATES_TOPIC, b"check_failed");
            }
        }
    });
}

fn install_update(app_handle: tauri::AppHandle, pubsub: elixirkit::PubSub) {
    tauri::async_runtime::spawn(async move {
        let update = app_handle
            .state::<PendingUpdate>()
            .0
            .lock()
            .unwrap()
            .clone();

        let Some(update) = update else {
            let _ = pubsub.broadcast(UPDATES_TOPIC, b"failed");
            return;
        };

        match update.download_and_install(|_, _| {}, || {}).await {
            Ok(()) => app_handle.restart(),
            Err(error) => {
                eprintln!("[rust] update install failed: {error}");
                let _ = pubsub.broadcast(UPDATES_TOPIC, b"failed");
            }
        }
    });
}

fn zoom_by(app_handle: &tauri::AppHandle, delta: f64) {
    let zoom_level = app_handle.state::<ZoomLevel>();

    let level = {
        let mut level = zoom_level.0.lock().expect("zoom level poisoned");
        *level = (*level + delta).clamp(MIN_ZOOM, MAX_ZOOM);
        *level
    };

    for window in app_handle.webview_windows().into_values() {
        let _ = window.set_zoom(level);
    }
}

fn zoom_to(app_handle: &tauri::AppHandle, level: f64) {
    let zoom_level = app_handle.state::<ZoomLevel>();
    *zoom_level.0.lock().expect("zoom level poisoned") = level;

    for window in app_handle.webview_windows().into_values() {
        let _ = window.set_zoom(level);
    }
}

fn create_window(app_handle: &tauri::AppHandle, port: u16) {
    if app_handle.get_webview_window(MAIN_WINDOW_LABEL).is_some() {
        focus_existing_window(app_handle);
        return;
    }

    let url = tauri::WebviewUrl::External(format!("http://127.0.0.1:{port}").parse().unwrap());
    // Prefer sessionStorage over create-time detect on reload.
    let theme = utils::os_theme_hint();
    let theme_init = [
        r#"(function () {
  try {
    var remembered = sessionStorage.getItem("voyager:os-theme");
    if (remembered === "dark" || remembered === "light") {
      window.__VOYAGER_OS_THEME__ = remembered;
      return;
    }
  } catch (e) {}
  window.__VOYAGER_OS_THEME__ = ""#,
        theme,
        r#"";
})();"#,
    ]
    .concat();
    let builder = tauri::WebviewWindowBuilder::new(app_handle, MAIN_WINDOW_LABEL, url)
        .title("Voyager")
        .inner_size(1280.0, 960.0)
        .min_inner_size(800.0, 800.0)
        // macOS zooms from the View menu; the built-in hotkeys would keep a second counter.
        .zoom_hotkeys_enabled(cfg!(not(target_os = "macos")))
        .initialization_script(theme_init);

    #[cfg_attr(target_os = "macos", allow(unused_variables))]
    let window = builder.build().unwrap();

    #[cfg(not(target_os = "macos"))]
    {
        let app_handle = window.app_handle().clone();
        window.on_window_event(move |event| {
            if let tauri::WindowEvent::Destroyed = event {
                app_handle.exit(0);
            }
        });
    }
}

fn elixir_command(
    rel_dir: &std::path::Path,
    data_dir: &std::path::Path,
    port: u16,
) -> std::process::Command {
    if cfg!(debug_assertions) {
        let mut command = elixirkit::mix("phx.server", &[]);
        command.current_dir("../../../");
        command.env("PORT", port.to_string());
        set_telemetry_env_dev(&mut command);
        command
    } else {
        let mut command = elixirkit::release(rel_dir, "voyager");
        command.env("PHX_SERVER", "true");
        command.env("PHX_HOST", "127.0.0.1");
        command.env("PORT", port.to_string());
        command.env("SECRET_KEY_BASE", utils::secret_key_base(data_dir));
        command.env("DATABASE_PATH", data_dir.join("voyager.db"));
        set_telemetry_env_prod(&mut command);
        command
    }
}

fn set_telemetry_env_dev(command: &mut std::process::Command) {
    if let Some(push_url) = std::env::var("TELEMETRY_PUSH_URL").ok() {
        command.env("TELEMETRY_PUSH_URL", push_url);
    }

    if let Some(api_key) = std::env::var("TELEMETRY_API_KEY").ok() {
        command.env("TELEMETRY_API_KEY", api_key);
    }
}

fn set_telemetry_env_prod(command: &mut std::process::Command) {
    if let Some(push_url) = option_env!("TELEMETRY_PUSH_URL") {
        command.env("TELEMETRY_PUSH_URL", push_url);
    }

    if let Some(api_key) = option_env!("TELEMETRY_API_KEY") {
        command.env("TELEMETRY_API_KEY", api_key);
    }
}
