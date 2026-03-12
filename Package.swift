// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Quorum",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "QuorumCore",
            targets: ["QuorumCore"]
        ),
        .executable(
            name: "quorum",
            targets: ["QuorumCLI"]
        ),
        .executable(
            name: "QuorumApp",
            targets: ["QuorumApp"]
        )
    ],
    targets: [
        .target(
            name: "QuorumCore",
            path: "Sources/QuorumCore"
        ),
        .executableTarget(
            name: "QuorumCLI",
            dependencies: ["QuorumCore"],
            path: "Sources/QuorumCLI"
        ),
        .executableTarget(
            name: "QuorumApp",
            dependencies: ["QuorumCore"],
            path: "Sources/QuorumApp"
        ),
        .testTarget(
            name: "QuorumCoreTests",
            dependencies: ["QuorumCore"],
            path: "Tests/QuorumCoreTests"
        )
    ]
)
