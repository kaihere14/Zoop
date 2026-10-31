// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Zoop",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ZoopShared", targets: ["ZoopShared"]),
        .executable(name: "ZoopHelper", targets: ["ZoopHelper"]),
        .executable(name: "zoop-bridge", targets: ["ZoopBridgeCLI"]),
    ],
    targets: [
        // Code linked by both the app (main user) and the helper (agent user). Foundation only.
        .target(name: "ZoopShared"),

        // Headless daemon that runs inside the agent user's GUI session (started by launchd).
        .executableTarget(name: "ZoopHelper", dependencies: ["ZoopShared"]),

        // Developer tool: drives the session bridge from the main user's terminal.
        .executableTarget(name: "ZoopBridgeCLI", dependencies: ["ZoopShared"]),

        .testTarget(name: "ZoopSharedTests", dependencies: ["ZoopShared"]),
        .testTarget(name: "ZoopHelperTests", dependencies: ["ZoopHelper", "ZoopShared"]),
    ]
)
