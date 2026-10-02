import AppKit
import Foundation
@testable import SwitchBladeCore

enum MenuBarControllerTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("MenuBarController/aboutVersionString_usesShortVersionOnly", aboutVersionStringUsesShortVersionOnly),
        ("MenuBarController/aboutTimestampString_formatsBuildTimestamp", aboutTimestampStringFormatsBuildTimestamp),
        ("MenuBarController/aboutPanelOptions_omitsVersionWhenBundleInfoMissing", aboutPanelOptionsOmitsMissingVersion),
        ("MenuBarController/secureInputStatus_formatsActiveAndStaleStates", secureInputStatusFormatsStates),
        ("MenuBarController/statusVisibility_forcesRelevantPermissionRecovery", statusVisibilityForcesRecovery),
        ("MenuBarController/permissionRecovery_routesExactMenuSelection", permissionRecoveryRoutesExactSelection),
        ("MenuBarController/mainMenu_hasConventionalLocalizedSections", mainMenuHasConventionalLocalizedSections),
        ("MenuBarController/quit_hasNoKeyboardEquivalent", quitHasNoKeyboardEquivalent),
        ("MenuBarController/settingsFrame_clampsSizeAndOriginToVisibleScreen", settingsFrameClampsToVisibleScreen),
        ("MenuBarController/settingsFrame_handlesTinyVisibleScreen", settingsFrameHandlesTinyScreen),
        ("MenuBarController/settingsConstruction_staysHiddenAndOutOfDock", settingsConstructionStaysHidden)
    ]

    @MainActor static func quitHasNoKeyboardEquivalent() throws {
        let app = NSApplication.shared
        let originalMenu = app.mainMenu
        let originalServicesMenu = app.servicesMenu
        let originalWindowsMenu = app.windowsMenu
        let originalHelpMenu = app.helpMenu
        defer {
            app.mainMenu = originalMenu
            app.servicesMenu = originalServicesMenu
            app.windowsMenu = originalWindowsMenu
            app.helpMenu = originalHelpMenu
        }
        let controller = MenuBarController()
        controller.installApplicationMainMenu()
        guard let menu = app.mainMenu,
              let appMenu = menu.items.first?.submenu,
              let quit = appMenu.items.first(where: { $0.action == #selector(NSApplication.terminate(_:)) }) else {
            throw TestFailure(message: "explicit Quit action must remain available", file: #filePath, line: #line)
        }
        // Substitute a harmless receiver before dispatching the real AppKit menu.
        let receiver = QuitReceiver()
        quit.target = receiver
        quit.action = #selector(QuitReceiver.quit(_:))
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "q", charactersIgnoringModifiers: "q",
                                           isARepeat: false, keyCode: 12) else {
            throw TestFailure(message: "could not create Cmd+Q event", file: #filePath, line: #line)
        }
        try expect(!menu.performKeyEquivalent(with: event), "Cmd+Q must never invoke the agent's Quit menu item")
        try expectEqual(receiver.calls, 0)
        try expectEqual(quit.keyEquivalent, "")
        appMenu.performActionForItem(at: appMenu.index(of: quit))
        try expectEqual(receiver.calls, 1, "explicit menu Quit must still dispatch")
    }

    @MainActor private final class QuitReceiver: NSObject {
        var calls = 0
        @objc func quit(_ sender: Any?) { calls += 1 }
    }

    @MainActor static func settingsConstructionStaysHidden() throws {
        let controller = MenuBarController()
        let window = controller.prepareSettingsWindow()
        defer { window.close() }
        try expect(!window.isVisible, "construction alone must not open settings")
        try expect(!window.isMiniaturizable, "settings must not create a minimized Dock tile")
        try expect(!window.isRestorable, "preferences must not return on a later launch")
        try expect(window.styleMask.contains(.closable))
        try expect(window.isResizable)
        try expect(controller.prepareSettingsWindow() === window, "explicit reopen must reuse the same settings window")
        window.performClose(nil)
        try expect(!window.isVisible)
        try expect(controller.prepareSettingsWindow() === window, "closing must preserve reusable settings state")
    }

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
            "Koottu 25.5.2026 klo 20.30"
        )
    }

    @MainActor static func aboutPanelOptionsOmitsMissingVersion() throws {
        let options = MenuBarController.aboutPanelOptions(bundleInfo: [:])
        try expect(options.isEmpty)
    }

    @MainActor static func secureInputStatusFormatsStates() throws {
        try expectEqual(
            MenuBarController.secureInputStatusTitle(for: .inactive, language: .english),
            "Secure Input: Off"
        )
        try expectEqual(
            MenuBarController.secureInputStatusTitle(
                for: SecureInputState(
                    pid: 36557,
                    process: SecureInputProcess(
                        pid: 36557,
                        displayName: "Preview",
                        bundleIdentifier: "com.apple.Preview",
                        executablePath: "/System/Applications/Preview.app/Contents/MacOS/Preview",
                        startTimeMicroseconds: 1,
                        isTrustedAppleSystemExecutable: true
                    )
                ),
                language: .english
            ),
            "Secure Input: Preview (pid 36557)"
        )
        try expectEqual(
            MenuBarController.secureInputStatusTitle(
                for: SecureInputState(pid: 36557, process: nil),
                language: .english
            ),
            "Secure Input: stuck pid 36557"
        )
    }

    @MainActor static func statusVisibilityForcesRecovery() throws {
        try expect(MenuBarController.shouldShowStatusItem(
            userPreference: false,
            secureInputActive: false,
            hasRelevantMissingPermissions: true
        ))
        try expect(MenuBarController.shouldShowStatusItem(
            userPreference: false,
            secureInputActive: true,
            hasRelevantMissingPermissions: false
        ))
        try expect(!MenuBarController.shouldShowStatusItem(
            userPreference: false,
            secureInputActive: false,
            hasRelevantMissingPermissions: false
        ))

        let screenRecordingOnly = PermissionState(
            hasAccessibility: true,
            hasScreenRecording: false
        )
        try expect(MenuBarController.shouldShowStatusItem(
            userPreference: false,
            secureInputActive: false,
            hasRelevantMissingPermissions: !screenRecordingOnly
                .missingPermissions(for: .livePreviews)
                .isEmpty
        ))
        try expect(!MenuBarController.shouldShowStatusItem(
            userPreference: false,
            secureInputActive: false,
            hasRelevantMissingPermissions: !screenRecordingOnly
                .missingPermissions(for: .iconsOnly)
                .isEmpty
        ))
    }

    @MainActor static func permissionRecoveryRoutesExactSelection() throws {
        let controller = MenuBarController()
        var opened: [PermissionKind] = []
        controller.onOpenPermissionSettings = { opened.append($0) }

        let accessibilityItem = NSMenuItem()
        accessibilityItem.representedObject = PermissionKind.accessibility.rawValue
        controller.openPermissionSettings(accessibilityItem)

        let invalidItem = NSMenuItem()
        invalidItem.representedObject = "not-a-permission"
        controller.openPermissionSettings(invalidItem)

        try expectEqual(opened, [.accessibility])
    }

    @MainActor static func mainMenuHasConventionalLocalizedSections() throws {
        try expectEqual(
            MenuBarController.mainMenuTopLevelTitles(language: .english),
            ["SwitchBlade", "Edit", "Window", "Help"]
        )
        try expectEqual(
            MenuBarController.mainMenuTopLevelTitles(language: .finnish),
            ["SwitchBlade", "Muokkaa", "Ikkuna", "Ohje"]
        )
    }

    @MainActor static func settingsFrameClampsToVisibleScreen() throws {
        let visible = NSRect(x: 100, y: 200, width: 800, height: 600)
        let proposed = NSRect(x: -500, y: -300, width: 1_200, height: 900)

        let result = MenuBarController.clampedFrame(proposed, inside: visible)
        let available = MenuBarController.availableFrame(inside: visible)

        try expectEqual(result, available)
        try expect(visible.contains(result), "clamped settings frame must remain on the visible screen")
    }

    @MainActor static func settingsFrameHandlesTinyScreen() throws {
        let visible = NSRect(x: -20, y: 40, width: 18, height: 14)
        let proposed = NSRect(x: 100, y: 100, width: 420, height: 700)

        let result = MenuBarController.clampedFrame(proposed, inside: visible)

        try expect(result.width > 0)
        try expect(result.height > 0)
        try expect(visible.contains(result), "tiny-screen frame must remain visible")
    }
}
