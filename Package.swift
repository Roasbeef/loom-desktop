// swift-tools-version: 6.2
import PackageDescription

// The client logic lives in packages that build with `swift build` alone, so
// the protocol core can be tested without Xcode and can later back an iOS
// target. The macOS app in App/ is a thin SwiftUI host over these libraries,
// and scripts/bundle.sh wraps its binary into a signed .app.
let package = Package(
    name: "LoomDesktop",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "LoomKit", targets: ["LoomKit"]),
        .library(name: "MissionKit", targets: ["MissionKit"]),
        .library(name: "Markup", targets: ["Markup"]),
        .executable(name: "loom-probe", targets: ["loom-probe"]),
        .executable(name: "Loom", targets: ["Loom"]),
    ],
    targets: [
        .target(name: "LoomKit"),
        .target(name: "Markup"),
        .target(name: "MissionKit", dependencies: ["LoomKit"]),
        .executableTarget(name: "loom-probe", dependencies: ["LoomKit", "MissionKit"]),
        .executableTarget(
            name: "Loom",
            dependencies: ["LoomKit", "MissionKit", "Markup"],
            path: "App/Sources"
        ),
        .testTarget(name: "LoomKitTests", dependencies: ["LoomKit", "MissionKit", "Markup"]),
    ]
)
