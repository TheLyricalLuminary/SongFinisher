// swift-tools-version: 6.0
import PackageDescription

// Domain is the innermost layer: models, service protocols, and pure logic.
// It depends on Foundation ONLY — this manifest is the enforcement mechanism.
let package = Package(
    name: "Domain",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"])
    ],
    targets: [
        .target(name: "Domain"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
    ]
)
