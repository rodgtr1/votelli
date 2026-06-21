// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Thin C wrapper exposing a minimal whisper.cpp API to Swift.
        .target(
            name: "CWhisper",
            cSettings: [
                .headerSearchPath("../../third_party/whisper.cpp/include"),
                .headerSearchPath("../../third_party/whisper.cpp/ggml/include")
            ]
        ),
        // Pure text logic, kept separate so it's unit-testable without linking whisper.
        .target(name: "MurmurText"),
        .executableTarget(
            name: "Murmur",
            dependencies: ["CWhisper", "MurmurText"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "third_party/whisper.cpp/build/bin",
                    "-lwhisper"
                ])
            ]
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["MurmurText"]
        )
    ]
)
