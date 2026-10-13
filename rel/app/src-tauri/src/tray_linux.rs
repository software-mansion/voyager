use std::sync::{Mutex, OnceLock};

use tauri::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

pub const TOPIC: &str = "tray";
const NODE_ID: &str = "node";
const MCP_ID: &str = "mcp";
const ERROR_ID: &str = "error";
const SESSION_ID: &str = "session";
const TOGGLE_MCP_ID: &str = "toggle_mcp";
const OPEN_ID: &str = "open";
const QUIT_ID: &str = "quit";

/// Status pushed by `Voyager.Services.TrayStatus`.
#[derive(serde::Deserialize)]
struct TrayStatus {
    connection: Option<Connection>,
    mcp: Option<Mcp>,
    last_connection: Option<Connection>,
    connecting: bool,
    error: Option<String>,
}

#[derive(serde::Deserialize)]
struct Connection {
    node: String,
    connector: String,
}

#[derive(serde::Deserialize)]
struct Mcp {
    url: String,
}

/// Tray rows whose text or state follow `TrayStatus`.
struct Tray {
    menu: Menu<tauri::Wry>,
    node: MenuItem<tauri::Wry>,
    mcp: MenuItem<tauri::Wry>,
    error: MenuItem<tauri::Wry>,
    session: MenuItem<tauri::Wry>,
    toggle_mcp: MenuItem<tauri::Wry>,
    open: MenuItem<tauri::Wry>,
    status: Mutex<Option<TrayStatus>>,
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
    let node = MenuItem::with_id(app, NODE_ID, "Starting…", true, None::<&str>)?;
    let mcp = MenuItem::with_id(app, MCP_ID, "MCP off", true, None::<&str>)?;
    let session = MenuItem::with_id(app, SESSION_ID, "Disconnect", false, None::<&str>)?;
    let toggle_mcp =
        MenuItem::with_id(app, TOGGLE_MCP_ID, "Start MCP Server", false, None::<&str>)?;
    let open = MenuItem::with_id(app, OPEN_ID, "Open Voyager", true, None::<&str>)?;

    let menu = Menu::with_items(
        app,
        &[
            &node,
            &mcp,
            &PredefinedMenuItem::separator(app)?,
            &session,
            &toggle_mcp,
            &PredefinedMenuItem::separator(app)?,
            &open,
            &MenuItem::with_id(app, QUIT_ID, "Quit Voyager", true, None::<&str>)?,
        ],
    )?;

    TrayIconBuilder::with_id("voyager")
        .icon(tauri::include_image!("icons/tray.png"))
        .menu(&menu)
        .on_menu_event(on_action)
        .build(app)?;

    Ok(Tray {
        menu,
        node,
        mcp,
        error: MenuItem::with_id(app, ERROR_ID, "", true, None::<&str>)?,
        session,
        toggle_mcp,
        open,
        status: Mutex::new(None),
    })
}

/// Window actions stay in Rust, the rest go to Elixir as the action the current status allows.
fn on_action(app_handle: &AppHandle, event: MenuEvent) {
    let Some(tray) = TRAY.get() else {
        return;
    };
    let action = {
        let status = tray.status.lock().unwrap();
        match (event.id().as_ref(), status.as_ref()) {
            (QUIT_ID, _) => return app_handle.exit(0),
            // /open blocks on NodeSession.current/0 during a connect.
            (NODE_ID | MCP_ID | OPEN_ID, Some(status)) if status.connecting => return,
            (NODE_ID | MCP_ID | OPEN_ID, _) => None,
            // broadcast() blocks the main thread until Elixir connects, which the first status follows.
            (_, None) => return,
            (ERROR_ID, _) => Some("dismiss_error"),
            (SESSION_ID, Some(status)) if status.connection.is_some() => Some("disconnect"),
            (SESSION_ID, _) => Some("connect"),
            (TOGGLE_MCP_ID, Some(status)) if status.mcp.is_some() => Some("mcp_off"),
            (TOGGLE_MCP_ID, _) => Some("mcp_on"),
            _ => return,
        }
    };

    match action {
        Some(action) => {
            let _ = app_handle
                .state::<elixirkit::PubSub>()
                .broadcast(TOPIC, action.as_bytes());
        }
        None => crate::open_window(app_handle),
    }
}

impl Tray {
    fn update(&self, status_json: &[u8]) {
        let status: TrayStatus = match serde_json::from_slice(status_json) {
            Ok(status) => status,
            Err(error) => return eprintln!("[rust] invalid tray status: {error}"),
        };

        let node = match (&status.connection, status.connecting) {
            (Some(c), _) => format!("Connected to {} · {}", c.node, c.connector),
            (None, true) => "Connecting…".to_string(),
            (None, false) => "Not connected".to_string(),
        };
        let (session, session_enabled) = match (&status.connection, &status.last_connection) {
            (Some(_), _) => ("Disconnect".to_string(), true),
            (None, Some(last)) => (format!("Connect to {}", last.node), !status.connecting),
            (None, None) => ("Disconnect".to_string(), false),
        };
        let (mcp, toggle_mcp) = match &status.mcp {
            Some(mcp) => (format!("MCP on · {}", mcp.url), "Stop MCP Server"),
            None => ("MCP off".to_string(), "Start MCP Server"),
        };
        let error = status.error.as_ref().map(|error| format!("⚠ {error}"));
        let open_enabled = !status.connecting;

        // Menu setters wait on the main thread, which on_action may hold behind this lock.
        let previous = self.status.lock().unwrap().replace(status);
        let error_shown = previous.is_some_and(|previous| previous.error.is_some());

        let _ = self.node.set_text(node);
        let _ = self.session.set_text(session);
        let _ = self.session.set_enabled(session_enabled);
        let _ = self.mcp.set_text(mcp);
        let _ = self.toggle_mcp.set_text(toggle_mcp);
        let _ = self.toggle_mcp.set_enabled(true);
        let _ = self.open.set_enabled(open_enabled);

        match (error, error_shown) {
            (Some(error), shown) => {
                let _ = self.error.set_text(error);
                if !shown {
                    let _ = self.menu.insert(&self.error, 0);
                }
            }
            (None, true) => {
                let _ = self.menu.remove(&self.error);
            }
            (None, false) => {}
        }
    }
}
