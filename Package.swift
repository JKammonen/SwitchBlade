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
        // Library with all production logic. Tests import this directly so
        // every type / extension is reachable without needing public modifiers
        // (via @testable). The app target depends on it as a real public API.
        .target(
            name: "SwitchBladeCore"
        ),
        // Thin executable target — just the @main entry point that constructs
        // the AppDelegate. Anything beyond AppMain.swift should live in the
        // SwitchBladeCore library.
        .executableTarget(
            name: "SwitchBlade",
            dependencies: ["SwitchBladeCore"]
        ),
        // Custom in-process test runner. Run with `swift run SwitchBladeTests`.
        // Doesn't require XCTest or swift-testing — works on Command Line Tools
        // without Xcode installed.
        .executableTarget(
            name: "SwitchBladeTests",
            dependencies: ["SwitchBladeCore"]
        )
    ]
)
