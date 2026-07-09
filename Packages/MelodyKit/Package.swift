// swift-tools-version: 6.0
import PackageDescription

// MelodyKit owns audio capture and real-time DSP. It may import Domain,
// AVFoundation, and Accelerate — and nothing from its peer packages.
let package = Package(
    name: "MelodyKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MelodyKit", targets: ["MelodyKit"])
    ],
    dependencies: [
        .package(path: "../Domain")
    ],
    targets: [
        .target(name: "MelodyKit", dependencies: ["Domain"]),
        .testTarget(name: "MelodyKitTests", dependencies: ["MelodyKit"]),
    ]
)
