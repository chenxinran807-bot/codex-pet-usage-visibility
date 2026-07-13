// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QuotaOverlay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "QuotaOverlayApp", targets: ["QuotaOverlayApp"])
    ],
    targets: [
        .executableTarget(name: "QuotaOverlayApp"),
        .testTarget(
            name: "QuotaOverlayTests",
            dependencies: ["QuotaOverlayApp"]
        )
    ]
)
