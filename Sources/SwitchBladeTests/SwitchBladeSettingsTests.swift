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
        ("Settings/launchAtLogin_initializesFromLiveStatus", launchAtLogin_initializesFromLiveStatus),
        ("Settings/launchAtLogin_successPersistsActualStatus", launchAtLogin_successPersistsActualStatus),
        ("Settings/launchAtLogin_failureRestoresActualStatus", launchAtLogin_failureRestoresActualStatus),
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

    @MainActor static func launchAtLogin_initializesFromLiveStatus() async throws {
        let userDefaults = makeIsolatedUserDefaults()
        userDefaults.set(true, forKey: "sb_launchAtLogin")
        let settings = SwitchBladeSettings(
            userDefaults: userDefaults,
            launchAtLoginController: LaunchAtLoginController.fake(currentStatus: .disabled)
        )

        try expectEqual(settings.launchAtLogin, false)
        try expectEqual(settings.launchAtLoginStatus, .disabled)
        try expectEqual(userDefaults.object(forKey: "sb_launchAtLogin") as? Bool, false)
    }

    @MainActor static func launchAtLogin_successPersistsActualStatus() async throws {
        let userDefaults = makeIsolatedUserDefaults()
        var requestedValues: [Bool] = []
        let settings = SwitchBladeSettings(
            userDefaults: userDefaults,
            launchAtLoginController: LaunchAtLoginController.fake(
                currentStatus: .disabled,
                setEnabled: { enabled in
                    requestedValues.append(enabled)
                    return .success(enabled ? .requiresApproval : .disabled)
                }
            )
        )

        settings.launchAtLogin = true

        try expectEqual(requestedValues, [true])
        try expectEqual(settings.launchAtLogin, false)
        try expectEqual(settings.launchAtLoginStatus, .requiresApproval)
        try expectEqual(userDefaults.object(forKey: "sb_launchAtLogin") as? Bool, false)
    }

    @MainActor static func launchAtLogin_failureRestoresActualStatus() async throws {
        let userDefaults = makeIsolatedUserDefaults()
        var liveStatus = LaunchAtLoginStatus.disabled
        let settings = SwitchBladeSettings(
            userDefaults: userDefaults,
            launchAtLoginController: LaunchAtLoginController.fake(
                currentStatus: liveStatus,
                setEnabled: { _ in .failure(LaunchAtLoginUpdateFailure(message: "denied")) }
            )
        )

        settings.launchAtLogin = true

        try expectEqual(settings.launchAtLogin, false)
        try expectEqual(settings.launchAtLoginStatus, .updateFailed)
        try expectEqual(userDefaults.object(forKey: "sb_launchAtLogin") as? Bool, false)

        liveStatus = .enabled
        let enabledSettings = SwitchBladeSettings(
            userDefaults: makeIsolatedUserDefaults(),
            launchAtLoginController: LaunchAtLoginController.fake(
                currentStatus: liveStatus,
                setEnabled: { _ in .failure(LaunchAtLoginUpdateFailure(message: "denied")) }
            )
        )

        enabledSettings.launchAtLogin = false

        try expectEqual(enabledSettings.launchAtLogin, true)
        try expectEqual(enabledSettings.launchAtLoginStatus, .updateFailed)
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

extension LaunchAtLoginController {
    static func fake(
        currentStatus: @autoclosure @escaping () -> LaunchAtLoginStatus,
        setEnabled: @escaping (Bool) -> Result<LaunchAtLoginStatus, LaunchAtLoginUpdateFailure> = { enabled in
            .success(enabled ? .enabled : .disabled)
        }
    ) -> LaunchAtLoginController {
        LaunchAtLoginController(
            currentStatus: currentStatus,
            setEnabled: setEnabled
        )
    }
}
