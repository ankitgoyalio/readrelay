// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadRelay",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "readrelay", targets: ["ReadRelay"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0")
    ],
    targets: [
        .executableTarget(name: "ReadRelay", dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ]),
        .testTarget(name: "ReadRelayTests", dependencies: ["ReadRelay"])
    ]
)
