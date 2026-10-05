// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VaultBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "VaultBarCore"
        ),
        .executableTarget(
            name: "VaultBarApp",
            dependencies: ["VaultBarCore"]
        ),
        .testTarget(
            name: "VaultBarCoreTests",
            dependencies: ["VaultBarCore"]
        )
    ]
)
