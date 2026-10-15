// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TurboTape",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TurboTapeKit", targets: ["TurboTapeKit"]),
        .executable(name: "turbotape-cli", targets: ["turbotape-cli"]),
    ],
    targets: [
        .target(name: "TurboTapeKit"),
        .executableTarget(name: "turbotape-cli", dependencies: ["TurboTapeKit"]),
        .testTarget(name: "TurboTapeKitTests", dependencies: ["TurboTapeKit"]),
    ]
)
