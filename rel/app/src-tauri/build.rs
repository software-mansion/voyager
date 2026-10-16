fn main() {
    // `option_env!("TELEMETRY_*")` is compile-time; rebuild when these change.
    println!("cargo:rerun-if-env-changed=TELEMETRY_PUSH_URL");
    println!("cargo:rerun-if-env-changed=TELEMETRY_API_KEY");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        let macos_min_version = std::env::var("MACOSX_DEPLOYMENT_TARGET")
            .expect("MACOSX_DEPLOYMENT_TARGET is set by `cargo tauri` and .cargo/config.toml");
        swift_rs::SwiftLinker::new(&macos_min_version)
            .with_package("VoyagerTray", "swift/VoyagerTray")
            .link();
        // Below macOS 12 SwiftUI links @rpath/libswift_Concurrency.dylib, which only the macOS 13
        // popover uses: weak so 10.15/11 still launch, rpath so 12+ finds the OS copy.
        println!("cargo:rustc-link-arg=-Wl,-weak-lswift_Concurrency");
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    }

    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(&["os_theme"])),
    )
    .expect("failed to run tauri-build");
}
