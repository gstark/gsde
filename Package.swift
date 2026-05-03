// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GSDE",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "GSDEApp", targets: ["GSDEApp"]),
        .executable(name: "GSDEChromiumHelper", targets: ["GSDEChromiumHelper"])
    ],
    targets: [
        .executableTarget(
            name: "GSDEApp",
            dependencies: ["GhosttyShim", "ChromiumStub"]
        ),
        .target(name: "GhosttyShim"),
        .target(
            name: "ChromiumStub",
            cSettings: [
                .unsafeFlags(["-I", "external/cef"])
            ]
        ),
        .executableTarget(
            name: "GSDEChromiumHelper",
            dependencies: ["ChromiumStub"],
            cSettings: [
                .unsafeFlags(["-I", "Sources/ChromiumStub/include"])
            ]
        )
    ]
)
