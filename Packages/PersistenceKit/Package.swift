// swift-tools-version: 6.0
import PackageDescription

// PersistenceKit quarantines SwiftData: @Model classes never leave this package.
// It may import Domain and SwiftData — nothing from its peer packages.
let package = Package(
    name: "PersistenceKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PersistenceKit", targets: ["PersistenceKit"])
    ],
    dependencies: [
        .package(path: "../Domain")
    ],
    targets: [
        .target(name: "PersistenceKit", dependencies: ["Domain"]),
        .testTarget(name: "PersistenceKitTests", dependencies: ["PersistenceKit"]),
    ]
)
