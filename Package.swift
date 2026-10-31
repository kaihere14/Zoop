// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Zoop",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ZoopShared", targets: ["ZoopShared"]),
        .executable(name: "Zoop", targets: ["ZoopApp"]),
        .executable(name: "ZoopHelper", targets: ["ZoopHelper"]),
        .executable(name: "zoop-bridge", targets: ["ZoopBridgeCLI"]),
        .executable(name: "zoop-agent", targets: ["ZoopAgentCLI"]),
    ],
    targets: [
        // Shared models and the persistent session bridge's wire protocol.
        .target(name: "ZoopShared"),
        .target(name: "ZoopAgents", dependencies: ["ZoopShared"]),
        .executableTarget(name: "ZoopApp", dependencies: ["ZoopShared", "ZoopAgents"], resources: [.process("Resources")]),
        // The helper stays isolated from AI orchestration and the main-session UI.
        .executableTarget(name: "ZoopHelper", dependencies: ["ZoopShared"]),
        .executableTarget(name: "ZoopBridgeCLI", dependencies: ["ZoopShared"]),
        // Runs the agents from a terminal, for testing the AI layer without the app.
        .executableTarget(name: "ZoopAgentCLI", dependencies: ["ZoopAgents", "ZoopShared"]),
        .testTarget(name: "ZoopSharedTests", dependencies: ["ZoopShared"]),
        .testTarget(name: "ZoopAgentsTests", dependencies: ["ZoopAgents", "ZoopShared"]),
        .testTarget(name: "ZoopHelperTests", dependencies: ["ZoopHelper", "ZoopShared"]),
    ]
)
