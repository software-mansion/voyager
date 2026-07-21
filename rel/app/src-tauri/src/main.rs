// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // Dev only — release uses compile-time env. Loads `.env` from the process cwd.
    #[cfg(debug_assertions)]
    let _ = dotenvy::dotenv();

    // Only fix `PATH` for production builds. It clobbers the `PATH` in dev mode.
    #[cfg(not(debug_assertions))]
    let _ = fix_path_env::fix();
    voyager_lib::run()
}
