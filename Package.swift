// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Evee",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EveeCore", targets: ["EveeCore"]),
        .executable(name: "Evee", targets: ["EveeApp"]),
        .executable(name: "evee-mcp", targets: ["EveeMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.14.8"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.4.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin", exact: "5.0.2"),
    ],
    targets: [
        .target(
            name: "EveeCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "EveeApp",
            dependencies: [
                "EveeCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin"),
            ]
        ),
        .executableTarget(name: "EveeMCP", dependencies: ["EveeCore"]),
        .testTarget(name: "EveeCoreTests", dependencies: ["EveeCore"]),
    ]
)
