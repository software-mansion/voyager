// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoyagerTray",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "VoyagerTray", type: .static, targets: ["VoyagerTray"])
    ],
    targets: [
        .target(name: "VoyagerTray")
    ]
)
