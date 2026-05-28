import AppKit
import Foundation
@testable import SwitchBladeCore

enum MenuBarControllerTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("MenuBarController/aboutVersionString_usesShortVersionOnly", aboutVersionStringUsesShortVersionOnly),
        ("MenuBarController/aboutTimestampString_formatsBuildTimestamp", aboutTimestampStringFormatsBuildTimestamp),
        ("MenuBarController/aboutPanelOptions_omitsVersionWhenBundleInfoMissing", aboutPanelOptionsOmitsMissingVersion)
    ]

    @MainActor static func aboutVersionStringUsesShortVersionOnly() throws {
        let settings = SwitchBladeSettings.shared
        let oldLanguage = settings.language
        settings.language = .english
        defer { settings.language = oldLanguage }

        let value = MenuBarController.aboutVersionString(bundleInfo: [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "42",
            "SwitchBladeBuildTimestamp": "2026-05-25T17:30:00Z"
        ])

        try expectEqual(value, "0.1.0")
    }

    @MainActor static func aboutTimestampStringFormatsBuildTimestamp() throws {
        try expectEqual(
            MenuBarController.formattedBuildTimestamp(
                from: "2026-05-25T17:30:00Z",
                timeZone: TimeZone(identifier: "Europe/Helsinki") ?? .gmt,
                language: .finnish
            ),
            "25.5.2026 klo 20.30"
        )
        try expectEqual(
            MenuBarController.aboutTimestampString(
                bundleInfo: [
                    "CFBundleShortVersionString": "0.1.0",
                    "CFBundleVersion": "42",
                    "SwitchBladeBuildTimestamp": "2026-05-25T17:30:00Z"
                ],
                timeZone: TimeZone(identifier: "Europe/Helsinki") ?? .gmt,
                language: .finnish
            ),
            "Buildattu 25.5.2026 klo 20.30"
        )
    }

    @MainActor static func aboutPanelOptionsOmitsMissingVersion() throws {
        let options = MenuBarController.aboutPanelOptions(bundleInfo: [:])
        try expect(options.isEmpty)
    }
}
