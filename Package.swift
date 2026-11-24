// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BolnaWebCall",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "BolnaWebCall", targets: ["BolnaWebCall"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", from: "158.0.0"),
    ],
    targets: [
        // SIP-over-WebSocket signalling, digest auth and session minting: Foundation only, unit-tested
        .target(name: "BolnaWebCallCore"),
        // Public API: wires the core to WebRTC media and a WebSocket
        .target(
            name: "BolnaWebCall",
            dependencies: ["BolnaWebCallCore", .product(name: "WebRTC", package: "WebRTC")]
        ),
        .testTarget(name: "BolnaWebCallCoreTests", dependencies: ["BolnaWebCallCore"]),
    ]
)
