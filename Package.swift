// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clip32",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Clip32", targets: ["Clip32"])],
    targets: [
        .target(name: "ClipCore"),
        .executableTarget(name: "Clip32", dependencies: ["ClipCore"]),
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"]),
        .testTarget(name: "Clip32Tests", dependencies: ["Clip32"])
    ]
)
