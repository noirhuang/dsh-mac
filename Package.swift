// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSHMac",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DSHMac",
            path: "Sources/DSHMac",
            resources: [.process("Resources")]
        )
    ],
    swiftLanguageModes: [.v5]
)
