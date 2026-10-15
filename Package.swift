// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JevAssist",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "JevAssist", targets: ["JevAssist"]),
        .executable(name: "JevAssistBridge", targets: ["JevAssistBridge"]),
        .library(name: "JevAssistCore", targets: ["JevAssistCore"])
    ],
    targets: [
        .target(name: "JevAssistCore"),
        .executableTarget(name: "JevAssist", dependencies: ["JevAssistCore"]),
        .executableTarget(name: "JevAssistBridge"),
        .testTarget(name: "JevAssistCoreTests", dependencies: ["JevAssistCore"])
    ]
)
