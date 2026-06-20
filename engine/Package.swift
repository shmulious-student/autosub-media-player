// swift-tools-version:5.9
// AutoSub Media Player — Mac native engine (SPEC §3, §4).
//
// The engine is a standalone Swift sidecar daemon shipped inside the .app. It
// owns the 12-stage pipeline, the persistent job queue, the SQLite source of
// truth, ASR (WhisperKit), and the bible-aware translation LLM.
//
// v0 status: scaffolding + stubs only. No AI model deps are added yet (see the
// TODOs in ASRService / BibleAwareTranslator). Keep heavy weights OFF the repo
// and OFF the internal disk — resolved from $AUTOSUB_MODELS (see ModelPaths).

import PackageDescription

let package = Package(
    name: "AutoSubEngine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AutoSubEngine", targets: ["AutoSubEngine"]),
        .library(name: "Engine", targets: ["Engine"]),
    ],
    dependencies: [
        // ASR — WhisperKit (MIT, ANE-accelerated). Models live on the external
        // drive ($AUTOSUB_MODELS/whisperkit), never bundled (docs/MODELS.md).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // TODO(v0): add a lightweight HTTP server for the loopback daemon, e.g.
        //   .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "Engine",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Engine"
        ),
        .executableTarget(
            name: "AutoSubEngine",
            dependencies: ["Engine"],
            path: "Sources/AutoSubEngine"
        ),
        .testTarget(
            name: "EngineTests",
            dependencies: ["Engine"],
            path: "Tests/EngineTests"
        ),
    ]
)
