// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "open_wearables_health_sdk",
    platforms: [.iOS("15.0")],
    products: [
        .library(name: "open-wearables-health-sdk", targets: ["open_wearables_health_sdk"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/the-momentum/open_wearables_ios_sdk.git",
            from: "0.14.0"
        )
    ],
    targets: [
        .target(
            name: "open_wearables_health_sdk",
            dependencies: [
                .product(name: "OpenWearablesHealthSDK", package: "open_wearables_ios_sdk")
            ],
            resources: [.process("Resources")],
        ),
    ]
)
