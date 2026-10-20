// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudePill",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "ClaudePill",
            path: "Sources/ClaudePill",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
