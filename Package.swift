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
        .library(name: "LoomCore", targets: ["LoomCore"]),
        .library(name: "LoomShell", targets: ["LoomShell"]),
        .executable(name: "loom-probe", targets: ["loom-probe"]),
        .executable(name: "Loom", targets: ["Loom"]),
    ],
    targets: [
        .target(name: "LoomKit"),
        .target(name: "Markup"),
        .target(name: "MissionKit", dependencies: ["LoomKit"]),
        // The pure core: value types that decide and never act. `scripts/core-purity.sh`
        // gates that nothing under Sources/LoomCore can block, read a clock or touch the OS.
        .target(name: "LoomCore", dependencies: ["LoomKit", "MissionKit"]),
        // The shell around the core: actors that own sockets and timers and carry out
        // what the core decided.
        .target(name: "LoomShell", dependencies: ["LoomKit", "LoomCore"]),
        .executableTarget(name: "loom-probe", dependencies: ["LoomKit", "MissionKit", "LoomShell"]),
        .executableTarget(
            name: "Loom",
            dependencies: ["LoomKit", "MissionKit", "Markup", "LoomCore", "LoomShell"],
            path: "App/Sources"
        ),
        .testTarget(name: "LoomKitTests", dependencies: ["LoomKit", "MissionKit", "Markup", "LoomShell"]),
        // The deterministic simulation: a seeded swarm over the production core.
        // The app's hosts: the executable target's controllers, built without a window.
        .testTarget(name: "LoomAppTests", dependencies: ["Loom", "LoomKit", "LoomShell"]),
        .testTarget(name: "LoomCoreTests", dependencies: ["LoomCore", "LoomKit", "MissionKit", "LoomShell"]),
    ]
)
