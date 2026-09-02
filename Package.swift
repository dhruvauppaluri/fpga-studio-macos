// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FPGAStudio",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "FPGAStudioCore", targets: ["FPGAStudioCore"]),
        .executable(name: "FPGAStudio", targets: ["FPGAStudio"])
    ],
    targets: [
        .target(
            name: "FPGAStudioCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "FPGAStudio",
            dependencies: ["FPGAStudioCore"]
        ),
        .testTarget(
            name: "FPGAStudioCoreTests",
            dependencies: ["FPGAStudioCore"]
        ),
        .testTarget(
            name: "FPGAStudioTests",
            dependencies: ["FPGAStudio", "FPGAStudioCore"]
        )
    ]
)
