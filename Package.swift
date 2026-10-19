// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThunderBridge",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ThunderBridge", targets: ["ThunderBridge"])],
    targets: [
        .target(name: "BridgeCore"),
        .executableTarget(name: "ThunderBridge", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
        .testTarget(name: "WorkflowTests", dependencies: ["ThunderBridge", "BridgeCore"])
    ]
)
