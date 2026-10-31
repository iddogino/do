// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DoKit",
    platforms: [.macOS(.v26)],
    products: [
        // Agent harness: prompt construction, response parsing, action execution, macOS I/O.
        // Deliberately free of MLX so it builds and tests quickly everywhere.
        .library(name: "DoCore", targets: ["DoCore"]),
        // Native MLX port of Mage-VL (Mage-ViT + Qwen3-4B) and its inference runtime.
        .library(name: "MageVL", targets: ["MageVL"]),
        // Developer tool: run one model turn on an image from the command line.
        .executable(name: "mage-cli", targets: ["mage-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.3.5")),
    ],
    targets: [
        .target(
            name: "DoCore",
            path: "Sources/DoCore"
        ),
        .target(
            name: "MageVL",
            dependencies: [
                "DoCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/MageVL"
        ),
        .executableTarget(
            name: "mage-cli",
            dependencies: ["MageVL", "DoCore"],
            path: "Sources/mage-cli"
        ),
        .testTarget(
            name: "DoCoreTests",
            dependencies: ["DoCore"],
            path: "Tests/DoCoreTests"
        ),
    ]
)
