// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VaultBar",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(
            name: "VaultBarCore"
        ),
        .executableTarget(
            name: "VaultBarApp",
            dependencies: ["VaultBarCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is embedded in Contents/Frameworks (Scripts/package_app.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "VaultBarCoreTests",
            dependencies: ["VaultBarCore"]
        )
    ]
)
