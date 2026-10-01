import AppKit
import Foundation
@testable import SwitchBladeCore

enum AppLifecycleTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("AppLifecycle/reopenDoesNotRequestSettings", reopenDoesNotRequestSettings),
        ("AppLifecycle/launchSettingsOnlyThroughExplicitMenuAction", launchSettingsOnlyThroughExplicitMenuAction),
        ("AppLifecycle/lastWindowCloseKeepsAgentAlive", lastWindowCloseKeepsAgentAlive),
        ("AppLifecycle/entryAndBundleKeepAccessoryIdentity", entryAndBundleKeepAccessoryIdentity)
    ]

    @MainActor static func reopenDoesNotRequestSettings() throws {
        let delegate = AppDelegate()
        for hasVisibleWindows in [false, true] {
            try expect(!delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: hasVisibleWindows),
                       "opening an already-running agent must not request a settings window")
        }
    }

    static func launchSettingsOnlyThroughExplicitMenuAction() throws {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/SwitchBladeCore/AppDelegate.swift"),
                                encoding: .utf8)
        let start = try requiredRange("public func applicationDidFinishLaunching", in: source)
        let end = try requiredRange("public func applicationWillTerminate", in: source)
        let launch = String(source[start.lowerBound..<end.lowerBound])
        let handler = try requiredRange("store.onOpenSettings = {", in: launch)
        let handlerEnd = try requiredRange("self.menuBarController = menuBar", in: launch)
        let explicitSettingsHandler = String(launch[handler.lowerBound..<handlerEnd.lowerBound])
        try expect(explicitSettingsHandler.contains("menuBar?.openSettings()"))
        let automaticLaunch = String(launch[..<handler.lowerBound]) + String(launch[handlerEnd.lowerBound...])
        try expect(!automaticLaunch.contains("openSettings()"),
                   "even missing permissions must use the status-menu recovery affordance, not automatic settings")
    }

    @MainActor static func lastWindowCloseKeepsAgentAlive() throws {
        let delegate: NSApplicationDelegate = AppDelegate()
        // Cocoa's default is to keep running when the optional callback is absent.
        try expect(!(delegate.applicationShouldTerminateAfterLastWindowClosed?(NSApplication.shared) ?? false))
    }

    static func entryAndBundleKeepAccessoryIdentity() throws {
        let entry = try String(contentsOf: root.appendingPathComponent("Sources/SwitchBlade/AppMain.swift"), encoding: .utf8)
        let build = try String(contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        try expect(entry.contains("application.setActivationPolicy(.accessory)"))
        try expect(build.contains("<key>LSUIElement</key>\n    <true/>"))
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func requiredRange(_ text: String, in source: String) throws -> Range<String.Index> {
        guard let range = source.range(of: text) else {
            throw TestFailure(message: "missing production entry point: \(text)", file: #filePath, line: #line)
        }
        return range
    }
}
