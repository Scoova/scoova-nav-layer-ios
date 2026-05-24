// swift-tools-version: 5.9
// Scoova Nav Layer — iOS / macOS Swift package.
//
// Module shape mirrors the Android SDK 1:1 so the integration story is
// the same in every language:
//
//     ScoovaNavLayerCore           — voice + cues + thresholds + spatial
//     ScoovaNavLayerUI             — SwiftUI drop-in components
//     ScoovaNavLayerScoovaRouting  — Scoova Valhalla routing adapter

import PackageDescription

let package = Package(
    name: "ScoovaNavLayer",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ScoovaNavLayerCore",           targets: ["ScoovaNavLayerCore"]),
        .library(name: "ScoovaNavLayerUI",             targets: ["ScoovaNavLayerUI"]),
        .library(name: "ScoovaNavLayerScoovaRouting",  targets: ["ScoovaNavLayerScoovaRouting"]),
    ],
    targets: [
        .target(
            name: "ScoovaNavLayerCore",
            path: "Sources/ScoovaNavLayerCore",
            // Pre-rendered dialect voice clips — bundled per-locale so the
            // rider hears authentic Cairo / Gulf / etc. accents instead of
            // the device's MSA-only on-board TTS. VoicePack loads them via
            // Bundle.module at runtime.
            resources: [
                .copy("Resources/voicepack"),
            ]
        ),
        .target(
            name: "ScoovaNavLayerUI",
            dependencies: ["ScoovaNavLayerCore"],
            path: "Sources/ScoovaNavLayerUI"
        ),
        .target(
            name: "ScoovaNavLayerScoovaRouting",
            dependencies: ["ScoovaNavLayerCore"],
            path: "Sources/ScoovaNavLayerScoovaRouting"
        ),
        .testTarget(
            name: "ScoovaNavLayerCoreTests",
            dependencies: ["ScoovaNavLayerCore"],
            path: "Tests/ScoovaNavLayerCoreTests"
        ),
        .testTarget(
            name: "ScoovaNavLayerScoovaRoutingTests",
            dependencies: ["ScoovaNavLayerScoovaRouting", "ScoovaNavLayerCore"],
            path: "Tests/ScoovaNavLayerScoovaRoutingTests"
        ),
    ]
)
