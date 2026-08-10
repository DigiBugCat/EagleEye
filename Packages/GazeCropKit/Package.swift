// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GazeCropKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "GazeCropKit", targets: ["GazeCropKit"]),
    ],
    targets: [
        .target(name: "GazeCropKit"),
        .testTarget(name: "GazeCropKitTests", dependencies: ["GazeCropKit"]),
    ]
)
