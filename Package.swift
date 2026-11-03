// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HackintoshSimplified",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "HackintoshSimplified", targets: ["HackintoshSimplified"])],
    targets: [
        .target(name: "HackintoshCore"),
        .executableTarget(name: "HackintoshSimplified", dependencies: ["HackintoshCore"]),
        .testTarget(name: "HackintoshCoreTests", dependencies: ["HackintoshCore"]),
    ]
)
