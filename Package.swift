// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Connector",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ConnectorCore"),
        .executableTarget(name: "Connector", dependencies: ["ConnectorCore"], resources: [.process("Resources")]),
        .executableTarget(name: "connector-cli", dependencies: ["ConnectorCore"]),
        .executableTarget(name: "connector-tests", dependencies: ["ConnectorCore"]),
    ]
)
