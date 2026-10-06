// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CinecoreKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
    ],
    products: [
        .library(name: "CinecoreKit", targets: ["CinecoreKit"]),
    ],
    targets: [
        .target(name: "CinecoreKit"),
        .testTarget(name: "CinecoreKitTests", dependencies: ["CinecoreKit"]),
    ]
)
