// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenIslandCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "OpenIslandCore",
            targets: ["OpenIslandCore"]
        ),
        .executable(
            name: "OpenIslandHooks",
            targets: ["OpenIslandHooks"]
        ),
    ],
    targets: [
        .target(
            name: "OpenIslandCore"
        ),
        .executableTarget(
            name: "OpenIslandHooks",
            dependencies: ["OpenIslandCore"]
        ),
    ]
)
