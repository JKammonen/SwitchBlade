@testable import SwitchBladeCore

enum SwitchBladeSettingsTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("Settings/hiddenApps_normalizesCommaSemicolonAndNewline", hiddenApps_normalizesTokens),
        ("Settings/hiddenApps_equalsPrefixProducesExactToken", hiddenApps_equalsPrefixProducesExactToken),
        ("Settings/hiddenApps_equalsWithEmptyBodyIsDropped", hiddenApps_equalsWithEmptyBodyIsDropped),
        ("Settings/hiddenApps_doubleEqualsBodyIsDropped", hiddenApps_doubleEqualsBodyIsDropped),
        ("Settings/hiddenApps_containsMatchesSubstring", hiddenApps_containsMatchesSubstring),
        ("Settings/hiddenApps_exactDoesNotMatchSubstring", hiddenApps_exactDoesNotMatchSubstring),
        ("Settings/hiddenApps_matchesBundleIdentifier", hiddenApps_matchesBundleIdentifier),
        ("Settings/windowScope_mirrorsThreadSafeFilterState", windowScope_mirrorsFilterState),
        ("Settings/performanceLogging_mirrorsThreadSafeState", performanceLogging_mirrorsState)
    ]

    @MainActor static func hiddenApps_normalizesTokens() async throws {
        let tokens = SwitchBladeSettings.normalizedHiddenAppTokens(
            from: " Safari, com.apple.Terminal;\n  Slack  ;"
        )

        try expectEqual(tokens, [
            .contains("safari"),
            .contains("com.apple.terminal"),
            .contains("slack")
        ])
    }

    @MainActor static func hiddenApps_equalsPrefixProducesExactToken() async throws {
        let tokens = SwitchBladeSettings.normalizedHiddenAppTokens(
            from: "=Code, Xcode, = Slack ,=com.apple.Terminal"
        )

        try expectEqual(tokens, [
            .exact("code"),
            .contains("xcode"),
            .exact("slack"),
            .exact("com.apple.terminal")
        ])
    }

    @MainActor static func hiddenApps_equalsWithEmptyBodyIsDropped() async throws {
        let tokens = SwitchBladeSettings.normalizedHiddenAppTokens(
            from: "=, =   , Safari"
        )

        try expectEqual(tokens, [.contains("safari")])
    }

    @MainActor static func hiddenApps_doubleEqualsBodyIsDropped() async throws {
        let tokens = SwitchBladeSettings.normalizedHiddenAppTokens(
            from: "==, ===, =Code"
        )

        try expectEqual(tokens, [.exact("code")])
    }

    @MainActor static func hiddenApps_containsMatchesSubstring() async throws {
        let token: HiddenAppToken = .contains("code")
        try expect(token.matches(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"))
        try expect(token.matches(appName: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode"))
        try expect(token.matches(appName: "Code", bundleIdentifier: nil))
    }

    @MainActor static func hiddenApps_exactDoesNotMatchSubstring() async throws {
        let token: HiddenAppToken = .exact("code")
        try expect(!token.matches(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"))
        try expect(!token.matches(appName: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode"))
        try expect(token.matches(appName: "Code", bundleIdentifier: nil))
        // Case-insensitive on the candidate side.
        try expect(token.matches(appName: "CODE", bundleIdentifier: nil))
    }

    @MainActor static func hiddenApps_matchesBundleIdentifier() async throws {
        let exact: HiddenAppToken = .exact("com.apple.terminal")
        try expect(exact.matches(appName: "Terminal", bundleIdentifier: "com.apple.Terminal"))
        try expect(!exact.matches(appName: "Terminal", bundleIdentifier: "com.apple.terminal.Helper"))

        let fuzzy: HiddenAppToken = .contains("terminal")
        try expect(fuzzy.matches(appName: "Terminal", bundleIdentifier: "com.apple.Terminal"))
        try expect(!fuzzy.matches(appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2"))
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
