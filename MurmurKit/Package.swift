// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MurmurKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
        .watchOS(.v11)
    ],
    products: [
        .library(name: "MurmurKit", targets: ["MurmurKit"]),
    ],
    targets: [
        .target(name: "MurmurKit"),
        .testTarget(name: "MurmurKitTests", dependencies: ["MurmurKit"]),
    ]
)
