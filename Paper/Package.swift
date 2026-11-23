// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Paper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Paper", path: "Sources/Paper"),
    ]
)
