// swift-tools-version: 6.0
import PackageDescription

// The client logic lives in packages that build with `swift build` alone, so
// the protocol core can be tested without Xcode and can later back an iOS
// target. The macOS app in App/ is a thin SwiftUI host over these libraries,
// and scripts/bundle.sh wraps its binary into a signed .app.
let package = Package(
    name: "LoomDesktop",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LoomKit", targets: ["LoomKit"]),
        .library(name: "SubstrateKit", targets: ["SubstrateKit"]),
        .library(name: "MissionKit", targets: ["MissionKit"]),
        .executable(name: "loom-probe", targets: ["loom-probe"]),
        .executable(name: "Loom", targets: ["Loom"]),
    ],
    targets: [
        .target(name: "LoomKit"),
        .target(name: "SubstrateKit"),
        .target(name: "MissionKit", dependencies: ["LoomKit", "SubstrateKit"]),
        .executableTarget(name: "loom-probe", dependencies: ["LoomKit", "SubstrateKit", "MissionKit"]),
        .executableTarget(
            name: "Loom",
            dependencies: ["LoomKit", "SubstrateKit", "MissionKit"],
            path: "App/Sources"
        ),
        .testTarget(name: "LoomKitTests", dependencies: ["LoomKit", "SubstrateKit", "MissionKit"]),
    ]
)
