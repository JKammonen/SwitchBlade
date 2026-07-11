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
        ("UIRender/switcherView_compactPermissionFooterRendersNarrow", compactPermissionFooterRendersNarrow),
        ("UIRender/settingsView_rendersWithPositiveFittingSize", settingsViewRenders),
        ("UIRender/panelController_constructsMaskedHostingPanel", panelControllerConstructs),
        ("UIRender/panelController_permissionChangeReflowsFooter", panelControllerPermissionChangeReflowsFooter)
    ]

    @MainActor
    static func switcherViewRenders() async throws {
        let previousLanguage = LocalizationState.selection
        LocalizationState.selection = .english
        defer { LocalizationState.selection = previousLanguage }
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, appName: "Alpha", title: "Dashboard")
                .withPreview(makeRenderPreview(color: .systemIndigo, label: "A")),
            makeItem(id: 2, appName: "Beta", title: "Messages")
                .withPreview(makeRenderPreview(color: .systemTeal, label: "B")),
            makeItem(id: 3, appName: "Gamma", title: "Report")
                .withPreview(makeRenderPreview(color: .systemOrange, label: "C"))
        ]
        await openSwitcher(store)
        store.updatePanelColumnCount(3)

        let layout = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            tileMinWidth: SwitchBladeSettings.shared.tileMinWidth,
            itemCount: 3,
            tileAspectRatio: SwitcherLayout.tileAspectRatio
        ))

        let host = NSHostingView(rootView: SwitcherView(store: store))
        host.frame = CGRect(origin: .zero, size: layout.panelFrame.size)
        host.layoutSubtreeIfNeeded()

        try expectGreaterThan(host.fittingSize.width, CGFloat(0))
        try expectGreaterThan(host.fittingSize.height, CGFloat(0))
        try writeRenderArtifactIfRequested(host, name: "switcher-default")
    }

    @MainActor
    static func compactPermissionFooterRendersNarrow() async throws {
        let previousLanguage = LocalizationState.selection
        LocalizationState.selection = .english
        defer { LocalizationState.selection = previousLanguage }
        let permissions = MockPermissionService()
        permissions.state = PermissionState(hasAccessibility: false, hasScreenRecording: false)
        let (store, catalog, _, _) = makeStore(permissions: permissions)
        catalog.visibleItems = [makeItem(id: 1, appName: "Alpha", title: "One")]
        await openSwitcher(store)

        let host = NSHostingView(rootView: SwitcherView(store: store))
        host.frame = CGRect(x: 0, y: 0, width: 326, height: 260)
        host.layoutSubtreeIfNeeded()

        try expectGreaterThan(host.fittingSize.width, CGFloat(0))
        try expectGreaterThan(host.fittingSize.height, CGFloat(0))
        try expectEqual(store.primaryMissingPermission, .accessibility)
        try writeRenderArtifactIfRequested(host, name: "switcher-permission-narrow")
    }

    @MainActor
    static func settingsViewRenders() throws {
        let previousLanguage = LocalizationState.selection
        LocalizationState.selection = .english
        defer { LocalizationState.selection = previousLanguage }
        // Fake launch-at-login controller so rendering never touches real login items.
        let settings = SwitchBladeSettings(
            userDefaults: makeIsolatedUserDefaults(),
            launchAtLoginController: LaunchAtLoginController.fake(currentStatus: .disabled)
        )
        settings.language = .english

        let host = NSHostingView(rootView: SettingsView(settings: settings))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        host.layoutSubtreeIfNeeded()

        try expectGreaterThan(host.fittingSize.height, CGFloat(0))
        try writeRenderArtifactIfRequested(host, name: "settings-english", background: .windowBackgroundColor)

        settings.language = .finnish
        settings.doubleModifierSwitchEnabled = false
        let finnishHost = NSHostingView(rootView: SettingsView(settings: settings))
        finnishHost.frame = host.frame
        finnishHost.layoutSubtreeIfNeeded()
        try expectGreaterThan(finnishHost.fittingSize.width, CGFloat(0))
        try writeRenderArtifactIfRequested(
            finnishHost,
            name: "settings-finnish",
            background: .windowBackgroundColor
        )

        let approvalSettings = SwitchBladeSettings(
            userDefaults: makeIsolatedUserDefaults(),
            launchAtLoginController: LaunchAtLoginController.fake(currentStatus: .requiresApproval)
        )
        let approvalHost = NSHostingView(rootView: SettingsView(
            settings: approvalSettings,
            permissionState: PermissionState(
                hasAccessibility: false,
                hasScreenRecording: false
            ),
            onOpenPermissionSettings: { _ in }
        ))
        approvalHost.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        approvalHost.layoutSubtreeIfNeeded()
        try expectGreaterThan(approvalHost.fittingSize.height, CGFloat(0))
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
        try expectEqual(probe.accessibilityRole, .window)
        try expectEqual(probe.accessibilitySubrole, .floatingWindow)
    }

    @MainActor
    static func panelControllerPermissionChangeReflowsFooter() async throws {
        let permissions = MockPermissionService()
        permissions.state = PermissionState(hasAccessibility: true, hasScreenRecording: true)
        let (store, catalog, _, _) = makeStore(permissions: permissions)
        catalog.visibleItems = [makeItem(id: 1, appName: "Alpha", title: "One")]
        await openSwitcher(store)

        let controller = SwitcherPanelController(store: store)
        controller.prepare(itemCount: 1)
        let withoutFooter = controller.constructionProbe.panelFrame.height

        permissions.state = PermissionState(hasAccessibility: false, hasScreenRecording: true)
        try expect(store.refreshPermissionState())
        controller.permissionStateDidChange()
        let withFooter = controller.constructionProbe.panelFrame.height

        try expect(
            abs(withFooter - withoutFooter - SwitcherLayoutCalculator.permissionFooterHeight) < 0.5
        )
    }

    @MainActor
    private static func writeRenderArtifactIfRequested(
        _ view: NSView,
        name: String,
        background: NSColor? = nil
    ) throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["SWITCHBLADE_RENDER_ARTIFACTS_DIR"],
              !outputDirectory.isEmpty else {
            return
        }

        let originalWantsLayer = view.wantsLayer
        let originalBackground = view.layer?.backgroundColor
        if let background {
            view.wantsLayer = true
            view.layer?.backgroundColor = background.cgColor
        }
        defer {
            view.layer?.backgroundColor = originalBackground
            view.wantsLayer = originalWantsLayer
        }

        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw TestFailure(
                message: "could not allocate bitmap for render artifact \(name)",
                file: #filePath,
                line: #line
            )
        }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw TestFailure(
                message: "could not encode render artifact \(name)",
                file: #filePath,
                line: #line
            )
        }

        let directoryURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try png.write(to: directoryURL.appendingPathComponent("\(name).png"), options: .atomic)
    }

    @MainActor
    private static func makeRenderPreview(color: NSColor, label: String) -> NSImage {
        let size = NSSize(width: 800, height: 500)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 180, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let textSize = text.size()
        text.draw(at: NSPoint(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2
        ))
        image.unlockFocus()
        return image
    }
}
