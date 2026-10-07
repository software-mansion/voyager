use std::sync::OnceLock;

use tauri::menu::{IconMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

pub const TOPIC: &str = "tray";
const NODE_ID: &str = "node";
const MCP_ID: &str = "mcp";
const DISCONNECT_ID: &str = "disconnect";
const TOGGLE_MCP_ID: &str = "toggle_mcp";
const OPEN_ID: &str = "open";
const QUIT_ID: &str = "quit";

/// Status pushed by `Voyager.Services.TrayStatus`.
#[derive(serde::Deserialize)]
struct TrayStatus {
    node: Option<String>,
    node_lost: bool,
    mcp_url: Option<String>,
}

/// Tray rows whose text, icon or state follow `TrayStatus`.
struct Tray {
    node: IconMenuItem<tauri::Wry>,
    mcp: IconMenuItem<tauri::Wry>,
    disconnect: MenuItem<tauri::Wry>,
    toggle_mcp: MenuItem<tauri::Wry>,
}

#[derive(Clone, Copy)]
enum Dot {
    On,
    Off,
    Alert,
}

static TRAY: OnceLock<Tray> = OnceLock::new();

/// Adds the tray icon with a native menu; Linux sends no tray clicks, so the menu is the whole UI.
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
    let tray = Tray {
        node: IconMenuItem::with_id(app, NODE_ID, "Starting…", true, None, None::<&str>)?,
        mcp: IconMenuItem::with_id(app, MCP_ID, "MCP off", true, None, None::<&str>)?,
        disconnect: MenuItem::with_id(app, DISCONNECT_ID, "Disconnect", false, None::<&str>)?,
        toggle_mcp: MenuItem::with_id(app, TOGGLE_MCP_ID, "Start MCP Server", false, None::<&str>)?,
    };
    set_dot(&tray.node, Dot::Off);
    set_dot(&tray.mcp, Dot::Off);

    let menu = Menu::with_items(
        app,
        &[
            &tray.node,
            &tray.mcp,
            &PredefinedMenuItem::separator(app)?,
            &tray.disconnect,
            &tray.toggle_mcp,
            &PredefinedMenuItem::separator(app)?,
            &MenuItem::with_id(app, OPEN_ID, "Open Voyager", true, None::<&str>)?,
            &MenuItem::with_id(app, QUIT_ID, "Quit Voyager", true, None::<&str>)?,
        ],
    )?;

    TrayIconBuilder::with_id("voyager")
        .icon(tauri::include_image!("icons/tray.png"))
        .menu(&menu)
        .on_menu_event(on_action)
        .build(app)?;

    Ok(tray)
}

/// Window actions stay in Rust, the rest go to Elixir.
fn on_action(app_handle: &AppHandle, event: MenuEvent) {
    match event.id().as_ref() {
        NODE_ID | MCP_ID | OPEN_ID => crate::open_window(app_handle),
        QUIT_ID => app_handle.exit(0),
        action @ (DISCONNECT_ID | TOGGLE_MCP_ID) => {
            let _ = app_handle
                .state::<elixirkit::PubSub>()
                .broadcast(TOPIC, action.as_bytes());
        }
        _ => {}
    }
}

impl Tray {
    fn update(&self, status_json: &[u8]) {
        let status: TrayStatus = match serde_json::from_slice(status_json) {
            Ok(status) => status,
            Err(error) => return eprintln!("[rust] invalid tray status: {error}"),
        };

        let (dot, text) = match (&status.node, status.node_lost) {
            (Some(node), false) => (Dot::On, format!("Connected to {node}")),
            (Some(node), true) => (Dot::Alert, format!("Lost connection to {node}")),
            (None, _) => (Dot::Off, "Not connected".to_string()),
        };
        set_dot(&self.node, dot);
        let _ = self.node.set_text(text);
        let _ = self
            .disconnect
            .set_enabled(status.node.is_some() && !status.node_lost);

        let (dot, text, action) = match &status.mcp_url {
            Some(url) => (Dot::On, format!("MCP on · {url}"), "Stop MCP Server"),
            None => (Dot::Off, "MCP off".to_string(), "Start MCP Server"),
        };
        set_dot(&self.mcp, dot);
        let _ = self.mcp.set_text(text);
        let _ = self.toggle_mcp.set_text(action);
        let _ = self.toggle_mcp.set_enabled(true);
    }
}

fn set_dot(item: &IconMenuItem<tauri::Wry>, dot: Dot) {
    let icon = match dot {
        Dot::On => tauri::include_image!("icons/dot-on.png"),
        Dot::Off => tauri::include_image!("icons/dot-off.png"),
        Dot::Alert => tauri::include_image!("icons/dot-alert.png"),
    };
    let _ = item.set_icon(Some(icon));
}
