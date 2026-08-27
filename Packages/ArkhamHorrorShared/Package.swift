// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ArkhamHorrorShared",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
        .tvOS("26.0"),
        .visionOS("26.0"),
    ],
    products: [
        .library(
            name: "ArkhamHorrorShared",
            targets: ["ArkhamHorrorShared"]
        ),
    ],
    targets: [
        .target(name: "ArkhamHorrorShared"),
        .testTarget(
            name: "ArkhamHorrorSharedTests",
            dependencies: ["ArkhamHorrorShared"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
