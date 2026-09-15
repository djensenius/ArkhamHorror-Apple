// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ArkhamHorrorShared",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .tvOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(
            name: "ArkhamHorrorShared",
            targets: ["ArkhamHorrorShared"]
        ),
    ],
    targets: [
        .target(
            name: "ArkhamHorrorShared",
            resources: [
                .copy("Resources"),
                .process("Localization"),
            ]
        ),
        .testTarget(
            name: "ArkhamHorrorSharedTests",
            dependencies: ["ArkhamHorrorShared"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
