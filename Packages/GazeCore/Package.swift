// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GazeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "GazeCore", targets: ["GazeCore"]),
    ],
    targets: [
        .target(name: "GazeCore"),
        .testTarget(name: "GazeCoreTests", dependencies: ["GazeCore"]),
    ]
)
