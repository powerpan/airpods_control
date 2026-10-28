// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirPodsMotion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MotionCore", targets: ["MotionCore"]),
        .library(name: "InteractionCore", targets: ["InteractionCore"]),
        .library(name: "MotionRuntime", targets: ["MotionRuntime"])
    ],
    targets: [
        .target(name: "MotionCore"),
        .target(name: "InteractionCore"),
        .target(name: "MotionRuntime", dependencies: ["MotionCore", "InteractionCore"]),
        .testTarget(name: "MotionCoreTests", dependencies: ["MotionCore"]),
        .testTarget(name: "InteractionCoreTests", dependencies: ["InteractionCore"]),
        .testTarget(name: "MotionRuntimeTests", dependencies: ["MotionRuntime", "MotionCore", "InteractionCore"])
    ]
)
