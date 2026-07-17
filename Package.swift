// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Votelli",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // The app's logic as a library, so a downstream package (e.g. a Pro build
        // that depends on this repo via a local path) can produce the same app with
        // extra features registered at startup. See AppExtensionPoints.
        .library(name: "VotelliCore", targets: ["VotelliCore"])
    ],
    dependencies: [
        // Sparkle powers the "Check for Updates…" menu item. It ships as a prebuilt
        // binary xcframework, so SwiftPM downloads it rather than compiling from
        // source — the first build fetches it. Sparkle is permissively (MIT-style)
        // licensed, so vendoring it into this MIT repo is fine. The app links it but
        // 'swift build' does NOT embed the framework into the .app; scripts/bundle.sh
        // does that (and signs it inside-out). See Updater.swift for the pull-only
        // posture — Sparkle never touches the network unless the user clicks.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
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
        .target(name: "VotelliText"),
        // All app logic lives here so it can be reused by a downstream Pro executable.
        // Note: this library deliberately carries NO whisper linker flags. The
        // '-L third_party/... -lwhisper' path is build-cwd relative, and SwiftPM only
        // permits unsafeFlags on root / local-path packages, so each *executable*
        // target links whisper itself with a path relative to its own build directory
        // (see the Votelli target below, and the Pro repo's executable).
        .target(
            name: "VotelliCore",
            dependencies: [
                "CWhisper",
                "VotelliText",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Thin executable: bootstrap only. The free app registers no extensions.
        .executableTarget(
            name: "Votelli",
            dependencies: ["VotelliCore"],
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
            name: "VotelliTests",
            dependencies: ["VotelliText"]
        )
    ]
)
