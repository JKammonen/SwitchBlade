@testable import SwitchBladeCore

enum SwitchBladeSettingsTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("Settings/hiddenApps_normalizesCommaSemicolonAndNewline", hiddenApps_normalizesTokens),
        ("Settings/windowScope_mirrorsThreadSafeFilterState", windowScope_mirrorsFilterState),
        ("Settings/performanceLogging_mirrorsThreadSafeState", performanceLogging_mirrorsState)
    ]

    @MainActor static func hiddenApps_normalizesTokens() async throws {
        let tokens = SwitchBladeSettings.normalizedHiddenAppTokens(
            from: " Safari, com.apple.Terminal;\n  Slack  ;"
        )

        try expectEqual(tokens, ["safari", "com.apple.terminal", "slack"])
    }

    @MainActor static func windowScope_mirrorsFilterState() async throws {
        let settings = SwitchBladeSettings.shared
        let oldScope = settings.windowScope
        defer { settings.windowScope = oldScope }

        settings.windowScope = .currentApp
        try expectEqual(WindowFilterState.scope, .currentApp)
        try expectEqual(settings.restrictToCurrentSpace, false)

        settings.restrictToCurrentSpace = true
        try expectEqual(settings.windowScope, .currentSpace)
        try expectEqual(WindowFilterState.scope, .currentSpace)
    }

    @MainActor static func performanceLogging_mirrorsState() async throws {
        let settings = SwitchBladeSettings.shared
        let oldMode = settings.performanceLogging
        defer { settings.performanceLogging = oldMode }

        settings.performanceLogging = .debug
        try expectEqual(PerformanceLoggingState.mode, .debug)

        settings.performanceLogging = .off
        try expectEqual(PerformanceLoggingState.mode, .off)
    }
}
