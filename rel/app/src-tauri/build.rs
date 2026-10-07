// Keep in sync with Package.swift platforms and bundle.macOS.minimumSystemVersion.
const MACOS_MIN_VERSION: &str = "12.0";

fn main() {
    // `option_env!("TELEMETRY_*")` is compile-time; rebuild when these change.
    println!("cargo:rerun-if-env-changed=TELEMETRY_PUSH_URL");
    println!("cargo:rerun-if-env-changed=TELEMETRY_API_KEY");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        swift_rs::SwiftLinker::new(MACOS_MIN_VERSION)
            .with_package("VoyagerTray", "swift/VoyagerTray")
            .link();

        // Swift 6 builds into out/Products/<Config>, which swift-rs 1.0.7 does not search.
        let configuration = if std::env::var("DEBUG").as_deref() == Ok("true") {
            "Debug"
        } else {
            "Release"
        };
        println!(
            "cargo:rustc-link-search=native={}/swift-rs/VoyagerTray/out/Products/{configuration}",
            std::env::var("OUT_DIR").unwrap()
        );
        // The Swift runtime ships with macOS and is linked through @rpath.
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    }

    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(&["os_theme"])),
    )
    .expect("failed to run tauri-build");
}
