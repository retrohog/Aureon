// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Aureon",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Aureon", targets: ["Aureon"]), .executable(name: "AureonHelper", targets: ["AureonHelper"])],
    targets: [
        // The privileged helper's logic, shared with the app so it can be tested without privileges.
        .target(name: "AureonHelperKit", path: "Sources/AureonHelperKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "AureonHelper", dependencies: ["AureonHelperKit"], path: "Sources/AureonHelper", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Real-time-safe C++ core of the neural upscaler (overlap-add stitcher and circuit breaker), exposed through a C header.
        .target(name: "AureonNeuralCore", path: "Sources/AureonNeuralCore"),
        .executableTarget(name: "Aureon", dependencies: ["AureonHelperKit", "AureonNeuralCore"], path: "Sources/Aureon", swiftSettings: [.swiftLanguageMode(.v5)]),
    ],
    cxxLanguageStandard: .cxx17
)
