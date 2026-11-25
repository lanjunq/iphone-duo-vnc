// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DuoVNC",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // What the iOS app links: RFBCore (client + security + decoders, re-exported), the mock server
        // for demo mode, and the pure app logic.
        .library(name: "RFBCore", targets: ["RFBCore"]),
        .library(name: "RFBMockServer", targets: ["RFBMockServer"]),
        .library(name: "DuoVNCKit", targets: ["DuoVNCKit"]),
        // UIKit-free session logic of the app (connection lifecycle, reconnect, TOFU, typing).
        .library(name: "DuoVNCSession", targets: ["DuoVNCSession"]),
        .executable(name: "rfbprobe", targets: ["rfbprobe"]),
    ],
    targets: [
        .target(name: "RFBBase"),
        .target(name: "RFBSecurity", dependencies: ["RFBBase"]),
        .target(name: "RFBDecoders", dependencies: ["RFBBase"], linkerSettings: [.linkedLibrary("z")]),
        .target(name: "RFBClient", dependencies: ["RFBBase"]),
        .target(name: "RFBMockServer", dependencies: ["RFBBase"], linkerSettings: [.linkedLibrary("z")]),
        .target(name: "RFBCore", dependencies: ["RFBBase", "RFBSecurity", "RFBDecoders", "RFBClient"]),
        .target(name: "DuoVNCKit"),
        .target(name: "DuoVNCSession", dependencies: ["RFBCore", "RFBMockServer", "DuoVNCKit"]),
        .executableTarget(name: "rfbprobe", dependencies: ["RFBCore", "RFBMockServer"]),
        .testTarget(name: "RFBBaseTests", dependencies: ["RFBBase"]),
        .testTarget(name: "RFBSecurityTests", dependencies: ["RFBSecurity"]),
        .testTarget(name: "RFBDecodersTests", dependencies: ["RFBDecoders"]),
        .testTarget(name: "RFBClientTests", dependencies: ["RFBClient"]),
        .testTarget(name: "RFBMockServerTests", dependencies: ["RFBMockServer"]),
        .testTarget(name: "DuoVNCKitTests", dependencies: ["DuoVNCKit"]),
        .testTarget(name: "DuoVNCSessionTests", dependencies: ["DuoVNCSession", "RFBCore", "RFBMockServer", "DuoVNCKit"]),
        .testTarget(name: "RFBCoreTests", dependencies: ["RFBCore", "RFBMockServer"]),
    ],
    swiftLanguageModes: [.v5]
)
