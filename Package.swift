// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GSDE",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "GSDEApp", targets: ["GSDEApp"])
    ],
    targets: [
        .executableTarget(
            name: "GSDEApp",
            dependencies: ["GhosttyShim", "ChromiumStub"]
        ),
        .target(name: "GhosttyShim"),
        .target(name: "ChromiumStub")
    ]
)
