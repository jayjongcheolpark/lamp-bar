// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LampBar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "LampBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LampBarTests",
            dependencies: ["LampBar"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
