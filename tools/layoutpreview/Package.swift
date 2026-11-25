// swift-tools-version: 6.0
// Draws a to-scale wireframe of the session screen from the real LayoutEngine / ToolbarLayout code.
import PackageDescription
let package = Package(
    name: "layoutpreview",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "DuoVNC", path: "../..")],
    targets: [.executableTarget(name: "layoutpreview", dependencies: [.product(name: "DuoVNCKit", package: "DuoVNC")])],
    swiftLanguageModes: [.v5]
)
