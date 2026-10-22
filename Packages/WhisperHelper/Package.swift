// swift-tools-version:6.0
import PackageDescription

// The on-device speech model behind lyrics generation (OpenAI's Whisper, converted to CoreML by Argmax's WhisperKit). Like the Smart DJ
// language model it lives in its own program, started when a song's lyrics are generated and quit a minute or two later, so the model's
// memory goes back to the system and a failure cannot take the player down.
//
// Build with:  xcodebuild -scheme AureonWhisper -configuration Release -destination 'platform=macOS' -derivedDataPath .build/xcode build
let package = Package(
    name: "AureonWhisper",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "AureonWhisper",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/AureonWhisper", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
