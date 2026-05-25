import AppKit
import Foundation
@testable import SwitchBladeCore

enum MenuBarControllerTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("MenuBarController/aboutVersionString_includesBuildTimestamp", aboutVersionStringIncludesBuildTimestamp),
        ("MenuBarController/aboutPanelOptions_omitsVersionWhenBundleInfoMissing", aboutPanelOptionsOmitsMissingVersion)
    ]

    @MainActor static func aboutVersionStringIncludesBuildTimestamp() throws {
        let settings = SwitchBladeSettings.shared
        let oldLanguage = settings.language
        settings.language = .english
        defer { settings.language = oldLanguage }

        let value = MenuBarController.aboutVersionString(bundleInfo: [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "42",
            "SwitchBladeBuildTimestamp": "2026-05-25T17:30:00Z"
        ])

        try expectEqual(value, "0.1.0 (42) - Built 2026-05-25T17:30:00Z")
    }

    @MainActor static func aboutPanelOptionsOmitsMissingVersion() throws {
        let options = MenuBarController.aboutPanelOptions(bundleInfo: [:])
        try expect(options.isEmpty)
    }
}
