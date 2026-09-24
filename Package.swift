// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Knolling",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Knolling", path: "Sources/Knolling")
    ]
)
