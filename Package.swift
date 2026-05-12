// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwitchBlade",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SwitchBlade",
            targets: ["SwitchBlade"]
        )
    ],
    targets: [
        .executableTarget(
            name: "SwitchBlade"
        )
    ]
)