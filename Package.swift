// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MazzyReceiver",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MazzyReceiver",
            dependencies: ["MazzyCore"],
            path: "Sources/MazzyReceiver"
        ),
        .target(
            name: "MazzyCore",
            path: "Sources/MazzyCore"
        ),
        .testTarget(
            name: "MazzyCoreTests",
            dependencies: ["MazzyCore"],
            path: "Tests/MazzyCoreTests"
        ),
    ]
)
