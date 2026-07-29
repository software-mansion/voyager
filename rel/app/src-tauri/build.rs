fn main() {
    // `option_env!("TELEMETRY_*")` is compile-time; rebuild when these change.
    println!("cargo:rerun-if-env-changed=TELEMETRY_PUSH_URL");
    println!("cargo:rerun-if-env-changed=TELEMETRY_API_KEY");

    tauri_build::build()
}
