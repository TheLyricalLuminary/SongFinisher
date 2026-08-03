// swift-tools-version: 6.0
import PackageDescription

// LyricEngine owns the AI providers (Foundation Models + offline) and the ranking
// pipeline. It may import Domain and Foundation — never AVFoundation or SwiftData,
// and nothing that talks to a network: generation is on-device by construction.
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
