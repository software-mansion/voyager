fn main() {
    // `option_env!("TELEMETRY_*")` is compile-time; rebuild when these change.
    println!("cargo:rerun-if-env-changed=TELEMETRY_PUSH_URL");
    println!("cargo:rerun-if-env-changed=TELEMETRY_API_KEY");

    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(&["os_theme"])),
    )
    .expect("failed to run tauri-build");
}
