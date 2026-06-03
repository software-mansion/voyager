mod utils;

use tauri::{
    menu::{MenuBuilder, SubmenuBuilder},
    Manager,
};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0").expect("failed to listen");

    tauri::Builder::default()
        .enable_macos_default_menu(false)
        .plugin(tauri_plugin_opener::init())
        .setup(move |app| {
            #[cfg(target_os = "macos")] // Remove default menu on macOS
            {
                let app_menu = SubmenuBuilder::new(app, "Voyager").quit().build()?;
                let menu = MenuBuilder::new(app).item(&app_menu).build()?;
                app.set_menu(menu)?;
            }

            let app_handle = app.handle().clone();
            let port =
                utils::available_port(4005).expect("failed to find available localhost port");

            pubsub.subscribe("messages", move |msg| {
                if msg == b"ready" {
                    create_window(&app_handle, port);
                } else {
                    println!("[rust] {}", String::from_utf8_lossy(msg));
                }
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

fn create_window(app_handle: &tauri::AppHandle, port: u16) {
    let n = app_handle.webview_windows().len() + 1;
    let url = tauri::WebviewUrl::External(format!("http://127.0.0.1:{port}").parse().unwrap());
    tauri::WebviewWindowBuilder::new(app_handle, format!("window-{}", n), url)
        .title("Voyager")
        .inner_size(800.0, 800.0)
        .min_inner_size(800.0, 800.0)
        .build()
        .unwrap();
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
        command.env("TELEMETRY_PUSH_URL", "http://127.0.0.1:4310/telemetry");
        command
    } else {
        let mut command = elixirkit::release(rel_dir, "voyager");
        command.env("PHX_SERVER", "true");
        command.env("PHX_HOST", "127.0.0.1");
        command.env("PORT", port.to_string());
        command.env("SECRET_KEY_BASE", utils::secret_key_base(data_dir));
        command.env("DATABASE_PATH", data_dir.join("voyager.db"));
        command.env("TELEMETRY_PUSH_URL", "http://127.0.0.1:4310/telemetry"); // This is temporary until we have a proper telemetry server #17
        command
    }
}
