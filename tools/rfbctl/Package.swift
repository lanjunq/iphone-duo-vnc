// swift-tools-version: 6.0
// Scriptable remote control for manual verification against a real server. Not part of the app.
import PackageDescription
let package = Package(
    name: "rfbctl",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "DuoVNC", path: "../..")],
    targets: [
        .executableTarget(name: "rfbctl", dependencies: [
            .product(name: "RFBCore", package: "DuoVNC"),
            .product(name: "DuoVNCKit", package: "DuoVNC"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
