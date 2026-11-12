// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TinyClash",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TinyClash",
            path: "Sources/TinyClash",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
