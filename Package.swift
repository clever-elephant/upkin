// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Upkin",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UpkinCore", targets: ["UpkinCore"]),
        .executable(name: "Upkin", targets: ["Upkin"])
    ],
    targets: [
        .target(name: "UpkinCore"),
        .executableTarget(
            name: "Upkin",
            dependencies: ["UpkinCore"]),
        .executableTarget(
            name: "UpkinCoreTests",
            dependencies: ["UpkinCore"])
    ]
)
