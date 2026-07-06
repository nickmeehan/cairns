// swift-tools-version: 6.0
// Floors are pinned by the current dev Mac (Xcode 16.2 / macOS 14.7) — see
// docs/decisions.md. macOS 14 keeps the `swift test` loop runnable locally.
import PackageDescription

let package = Package(
    name: "CairnsKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CairnsKit", targets: ["CairnsKit"]),
    ],
    targets: [
        .target(name: "CairnsKit"),
        .testTarget(name: "CairnsKitTests", dependencies: ["CairnsKit"]),
    ]
)
