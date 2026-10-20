use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};

use serde::de::IgnoredAny;
use tauri::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

pub const TOPIC: &str = "tray";
const CONNECT_ID: &str = "connect";
const MCP_ID: &str = "mcp";
const OPEN_ID: &str = "open";
const HIDE_ID: &str = "hide";
const QUIT_ID: &str = "quit";

/// Status pushed by `Voyager.Services.TrayStatus`.
#[derive(serde::Deserialize)]
struct TrayStatus {
    connection: Option<Connection>,
    mcp: Option<IgnoredAny>,
    last_connection: Option<Connection>,
    connecting: bool,
}

#[derive(serde::Deserialize)]
struct Connection {
    node: String,
}

struct Tray {
    status: MenuItem<tauri::Wry>,
    connect: MenuItem<tauri::Wry>,
    mcp: MenuItem<tauri::Wry>,
    open: MenuItem<tauri::Wry>,
    connected: AtomicBool,
    mcp_on: AtomicBool,
}

static TRAY: OnceLock<Tray> = OnceLock::new();

/// Adds the tray icon with a native menu.
pub fn setup(app: &tauri::App) {
    match build(app) {
        Ok(tray) => {
            let _ = TRAY.set(tray);
        }
        Err(error) => eprintln!("[rust] tray setup failed: {error}"),
    }
}

pub fn update(status_json: &[u8]) {
    if let Some(tray) = TRAY.get() {
        tray.update(status_json);
    }
}

fn build(app: &tauri::App) -> tauri::Result<Tray> {
    let status = MenuItem::new(app, "Starting…", false, None::<&str>)?;
    // broadcast() blocks the main thread until Elixir connects, which the first status follows.
    let connect = MenuItem::with_id(app, CONNECT_ID, "Reconnect", false, None::<&str>)?;
    let mcp = MenuItem::with_id(app, MCP_ID, "MCP Server: OFF", false, None::<&str>)?;
    let open = MenuItem::with_id(app, OPEN_ID, "Open Voyager", false, None::<&str>)?;

    let menu = Menu::with_items(
        app,
        &[
            &status,
            &connect,
            &PredefinedMenuItem::separator(app)?,
            &mcp,
            &PredefinedMenuItem::separator(app)?,
            &open,
            &MenuItem::with_id(app, HIDE_ID, "Hide to Tray", true, None::<&str>)?,
            &MenuItem::with_id(app, QUIT_ID, "Quit", true, None::<&str>)?,
        ],
    )?;

    TrayIconBuilder::with_id("voyager")
        .icon(tauri::include_image!("icons/icon.png"))
        .menu(&menu)
        .on_menu_event(on_action)
        .build(app)?;

    Ok(Tray {
        status,
        connect,
        mcp,
        open,
        connected: AtomicBool::new(false),
        mcp_on: AtomicBool::new(false),
    })
}

/// Window actions stay in Rust, the rest go to Elixir.
fn on_action(app_handle: &AppHandle, event: MenuEvent) {
    let action = match event.id().as_ref() {
        OPEN_ID => return crate::open_window(app_handle),
        HIDE_ID => {
            if let Some(window) = app_handle.get_webview_window(crate::MAIN_WINDOW_LABEL) {
                let _ = window.destroy();
            }
            return;
        }
        QUIT_ID => return app_handle.exit(0),
        CONNECT_ID
            if TRAY
                .get()
                .is_some_and(|tray| tray.connected.load(Ordering::Relaxed)) =>
        {
            "disconnect"
        }
        CONNECT_ID => "connect",
        MCP_ID
            if TRAY
                .get()
                .is_some_and(|tray| tray.mcp_on.load(Ordering::Relaxed)) =>
        {
            "mcp_off"
        }
        MCP_ID => "mcp_on",
        _ => return,
    };
    let _ = app_handle
        .state::<elixirkit::PubSub>()
        .broadcast(TOPIC, action.as_bytes());
}

impl Tray {
    fn update(&self, status_json: &[u8]) {
        let status: TrayStatus = match serde_json::from_slice(status_json) {
            Ok(status) => status,
            Err(error) => return eprintln!("[rust] invalid tray status: {error}"),
        };

        let text = match &status.connection {
            Some(connection) => format!("Connected to {}", connection.node),
            None => "Not connected".to_string(),
        };
        // The status does not name the node being connected, which may not be last_connection.
        let (connect_text, connect_enabled) = match (&status.connection, &status.last_connection) {
            _ if status.connecting => ("Connecting…".to_string(), false),
            (Some(_), _) => ("Disconnect".to_string(), true),
            (None, Some(last)) => (format!("Reconnect to {}", last.node), true),
            (None, None) => ("Reconnect".to_string(), false),
        };
        let mcp_on = status.mcp.is_some();
        self.connected
            .store(status.connection.is_some(), Ordering::Relaxed);
        self.mcp_on.store(mcp_on, Ordering::Relaxed);

        let _ = self.status.set_text(text);
        let _ = self.connect.set_text(connect_text);
        let _ = self.connect.set_enabled(connect_enabled);
        let _ = self.mcp.set_text(if mcp_on {
            "MCP Server: ON"
        } else {
            "MCP Server: OFF"
        });
        let _ = self.mcp.set_enabled(true);
        // /open blocks on NodeSession.current/0 during a connect.
        let _ = self.open.set_enabled(!status.connecting);
    }
}
