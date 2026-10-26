// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Snappabl",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Snappabl",
            path: "Sources/Snappabl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
