// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacSCP",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "MacSCPCore", targets: ["MacSCPCore"]),
        .library(name: "MacSCPBackends", targets: ["MacSCPBackends"]),
        .library(name: "MacSCPUI", targets: ["MacSCPUI"]),
        .executable(name: "macscp-benchmark", targets: ["MacSCPBenchmark"]),
        .executable(name: "MacSCP", targets: ["MacSCPApp"]),
        .executable(name: "macscp-cli", targets: ["MacSCPCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.0"),
        .package(url: "https://github.com/GitSwiftHQ/Traversio.git", from: "1.0.6"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MacSCPCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "MacSCPBackends",
            dependencies: [
                "MacSCPCore",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "Traversio", package: "Traversio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "MacSCPBenchmark",
            dependencies: [
                "MacSCPCore",
                "MacSCPBackends",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "MacSCPApp",
            dependencies: [
                "MacSCPCore",
                "MacSCPBackends",
                "MacSCPUI",
            ],
            path: "Sources/MacSCPApp"
        ),
        .executableTarget(
            name: "MacSCPCLI",
            dependencies: [
                "MacSCPCore",
                "MacSCPBackends",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "MacSCPUI",
            dependencies: [
                "MacSCPCore",
                "MacSCPBackends",
            ]
        ),
        .testTarget(
            name: "MacSCPTests",
            dependencies: ["MacSCPCore", "MacSCPBackends", "MacSCPUI"]
        ),
    ]
)
