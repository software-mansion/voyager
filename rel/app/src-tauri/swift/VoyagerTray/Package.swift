// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoyagerTray",
    // Keep in sync with bundle.macOS.minimumSystemVersion in tauri.conf.json.
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VoyagerTray", type: .static, targets: ["VoyagerTray"])
    ],
    targets: [
        .target(name: "VoyagerTray")
    ]
)
