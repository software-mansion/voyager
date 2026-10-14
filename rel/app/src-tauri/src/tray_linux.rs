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
const QUIT_ID: &str = "quit";

/// Status pushed by `Voyager.Services.TrayStatus`.
#[derive(serde::Deserialize)]
struct TrayStatus {
    connection: Option<Connection>,
    mcp: Option<IgnoredAny>,
    last_connection: Option<IgnoredAny>,
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
    mcp_on: AtomicBool,
}

static TRAY: OnceLock<Tray> = OnceLock::new();

/// Adds the tray icon with a native menu when the desktop has a tray host.
pub fn setup(app: &tauri::App) {
    if !tray_host_available() {
        return;
    }
    match build(app) {
        Ok(tray) => {
            let _ = TRAY.set(tray);
        }
        Err(error) => eprintln!("[rust] tray setup failed: {error}"),
    }
}

pub fn available() -> bool {
    TRAY.get().is_some()
}

pub fn update(status_json: &[u8]) {
    if let Some(tray) = TRAY.get() {
        tray.update(status_json);
    }
}

fn build(app: &tauri::App) -> tauri::Result<Tray> {
    let status = MenuItem::new(app, "Starting…", false, None::<&str>)?;
    // broadcast() blocks the main thread until Elixir connects, which the first status follows.
    let connect = MenuItem::with_id(app, CONNECT_ID, "Connect", false, None::<&str>)?;
    let mcp = MenuItem::with_id(app, MCP_ID, "MCP: OFF", false, None::<&str>)?;
    let open = MenuItem::with_id(app, OPEN_ID, "Open Voyager", true, None::<&str>)?;

    let menu = Menu::with_items(
        app,
        &[
            &status,
            &connect,
            &mcp,
            &PredefinedMenuItem::separator(app)?,
            &open,
            &MenuItem::with_id(app, QUIT_ID, "Quit", true, None::<&str>)?,
        ],
    )?;

    TrayIconBuilder::with_id("voyager")
        .icon(tauri::include_image!("icons/tray.png"))
        .icon_as_template(true)
        .menu(&menu)
        .on_menu_event(on_action)
        .build(app)?;

    Ok(Tray {
        status,
        connect,
        mcp,
        open,
        mcp_on: AtomicBool::new(false),
    })
}

/// Window actions stay in Rust, the rest go to Elixir.
fn on_action(app_handle: &AppHandle, event: MenuEvent) {
    let action = match event.id().as_ref() {
        OPEN_ID => return crate::open_window(app_handle),
        QUIT_ID => return app_handle.exit(0),
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
        let can_connect =
            status.connection.is_none() && status.last_connection.is_some() && !status.connecting;
        let mcp_on = status.mcp.is_some();
        self.mcp_on.store(mcp_on, Ordering::Relaxed);

        let _ = self.status.set_text(text);
        let _ = self.connect.set_text(if status.connecting {
            "Connecting…"
        } else {
            "Connect"
        });
        let _ = self.connect.set_enabled(can_connect);
        let _ = self
            .mcp
            .set_text(if mcp_on { "MCP: ON" } else { "MCP: OFF" });
        let _ = self.mcp.set_enabled(true);
        // /open blocks on NodeSession.current/0 during a connect.
        let _ = self.open.set_enabled(!status.connecting);
    }
}

/// Linux needs a StatusNotifierItem host, which stock GNOME lacks without the AppIndicator extension.
fn tray_host_available() -> bool {
    std::process::Command::new("gdbus")
        .args([
            "call",
            "--session",
            "--dest",
            "org.freedesktop.DBus",
            "--object-path",
            "/org/freedesktop/DBus",
            "--method",
            "org.freedesktop.DBus.NameHasOwner",
            "org.kde.StatusNotifierWatcher",
        ])
        .output()
        .is_ok_and(|output| String::from_utf8_lossy(&output.stdout).contains("true"))
}
