// swift-tools-version: 5.10
import PackageDescription

// Keep the GPU runtime separate so Bob still builds on macOS 14 and starts
// without loading model weights or the MLX dependency graph.
let package = Package(
    name: "BobDecision",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift.git",
                 revision: "1aed9dfa57f900eb6ffd6671246f4712819a0e75"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6")
    ],
    targets: [
        .executableTarget(name: "BobDecision", dependencies: [
            .product(name: "Clef", package: "speech-swift"),
            .product(name: "MLX", package: "mlx-swift")
        ])
    ]
)
