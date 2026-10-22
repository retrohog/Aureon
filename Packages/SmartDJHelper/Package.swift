// swift-tools-version:6.2
import PackageDescription

// The on-device language model behind Smart DJ. It lives in its own program (started when Smart DJ is switched on, quit when it is
// switched off) for three reasons: the model's memory goes back to the system the moment it is unloaded, a crash or a missing
// model cannot take the player down, and MLX needs Xcode's Metal compiler to build, which the player itself does not.
//
// Build with:  xcodebuild -scheme AureonSmartDJ -configuration Release -destination 'platform=macOS' -derivedDataPath .build/xcode build
let package = Package(
    name: "AureonSmartDJ",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "AureonSmartDJ",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"), .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"), .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"), .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/AureonSmartDJ", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
