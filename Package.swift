// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpaceLens",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SpaceLens",
            path: "Sources/SpaceLens"
        )
    ]
)
