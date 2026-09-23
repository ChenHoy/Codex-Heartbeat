// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexHeartbeat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexHeartbeat", targets: ["CodexHeartbeat"]),
        .executable(name: "codex-heartbeat", targets: ["HeartbeatLauncher"])
    ],
    targets: [
        .target(name: "HeartbeatSystem"),
        .target(name: "HeartbeatCore", dependencies: ["HeartbeatSystem"]),
        .executableTarget(name: "CodexHeartbeat", dependencies: ["HeartbeatCore"]),
        .executableTarget(name: "HeartbeatLauncher", dependencies: ["HeartbeatCore", "HeartbeatSystem"]),
        .testTarget(name: "HeartbeatCoreTests", dependencies: ["HeartbeatCore", "HeartbeatSystem"])
    ]
)
