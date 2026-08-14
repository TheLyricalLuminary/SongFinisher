// swift-tools-version: 6.0
import PackageDescription

// LyricEngine owns the AI providers (Foundation Models + offline) and the ranking
// pipeline. Its allowlist is Domain, Foundation, and FoundationModels — the last of which
// runs Apple's on-device model and reaches no server. Never AVFoundation or SwiftData, and
// nothing that talks to a network: generation is on-device by construction.
//
// "By construction" is checked, not asserted — `tools/check_no_network.sh` fails the build
// on a networking import, a networking API, or a package dependency fetched from a URL,
// and CI runs it on every pull request.
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
