// swift-tools-version: 6.0
import PackageDescription

// LyricEngine owns the AI providers (Claude + offline) and the ranking pipeline.
// It may import Domain and Foundation (URLSession) — never AVFoundation or SwiftData.
let package = Package(
    name: "LyricEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LyricEngine", targets: ["LyricEngine"])
    ],
    dependencies: [
        .package(path: "../Domain")
    ],
    targets: [
        .target(
            name: "LyricEngine",
            dependencies: ["Domain"],
            resources: [.copy("Resources/lexicon.bin")]
        ),
        .testTarget(name: "LyricEngineTests", dependencies: ["LyricEngine"]),
    ]
)
