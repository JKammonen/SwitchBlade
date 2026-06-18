import AppKit
import SwiftUI
@testable import SwitchBladeCore

/// In-process AppKit/SwiftUI smoke tests. These run under `swift run
/// SwitchBladeTests` on a logged-in macOS session with no TCC grant and no
/// manual clicking — they construct the real views/panel and force layout to
/// catch render/binding crashes that pure-logic tests can't reach. They do NOT
/// cover window capture, AX, or anything title/content-dependent: the test
/// binary has a different code signature than the signed app, so it lacks
/// Screen Recording / Accessibility permission.
enum UIRenderSmokeTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("UIRender/switcherView_rendersWithPositiveFittingSize", switcherViewRenders),
        ("UIRender/settingsView_rendersWithPositiveFittingSize", settingsViewRenders),
        ("UIRender/panelController_constructsMaskedHostingPanel", panelControllerConstructs)
    ]

    @MainActor
    static func switcherViewRenders() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, appName: "Alpha", title: "One"),
            makeItem(id: 2, appName: "Beta", title: "Two"),
            makeItem(id: 3, appName: "Gamma", title: "Three")
        ]
        await openSwitcher(store)

        let host = NSHostingView(rootView: SwitcherView(store: store))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()

        try expectGreaterThan(host.fittingSize.width, CGFloat(0))
        try expectGreaterThan(host.fittingSize.height, CGFloat(0))
    }

    @MainActor
    static func settingsViewRenders() throws {
        // Fake launch-at-login controller so rendering never touches real login items.
        let settings = SwitchBladeSettings(
            userDefaults: makeIsolatedUserDefaults(),
            launchAtLoginController: LaunchAtLoginController.fake(currentStatus: .disabled)
        )

        let host = NSHostingView(rootView: SettingsView(settings: settings))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        host.layoutSubtreeIfNeeded()

        try expectGreaterThan(host.fittingSize.height, CGFloat(0))
    }

    @MainActor
    static func panelControllerConstructs() throws {
        let (store, _, _, _) = makeStore()
        let controller = SwitcherPanelController(store: store)

        let probe = controller.constructionProbe
        try expect(probe.contentViewIsHostingView, "panel contentView should be the SwitcherView hosting view")
        try expect(probe.hasCardMask, "hosting view should carry the CAShapeLayer corner mask")
        try expect(!probe.panelIsOpaque, "panel must be non-opaque for transparent corners")
        try expectEqual(probe.panelLevel, .statusBar)
    }
}
