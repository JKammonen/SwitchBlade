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
        ("UIRender/applicationFallback_rendersAsIconOnlyTile", applicationFallbackRendersAsIconOnlyTile),
        ("UIRender/minimizedMerge_reflowsAndRendersThirteenthItem", minimizedMergeReflowsAndRendersThirteenthItem),
        ("UIRender/fifteenItems_renderAsBalancedThreeRows", fifteenItemsRenderAsBalancedThreeRows),
        ("UIRender/switcherColumns_remainFixedAtPanelTileWidth", switcherColumnsRemainFixedAtPanelTileWidth),
        ("UIRender/switcherView_wiresFixedColumnContract", switcherViewWiresFixedColumnContract),
        ("UIRender/switcherView_compactPermissionFooterRendersNarrow", compactPermissionFooterRendersNarrow),
        ("UIRender/settingsView_rendersWithPositiveFittingSize", settingsViewRenders),
        ("UIRender/objectSelectorWidthBinding_updatesOnlySelectorWidth", objectSelectorWidthBindingUpdatesOnlySelectorWidth),
        ("UIRender/settingsView_wiresObjectSelectorBinding", settingsViewWiresObjectSelectorBinding),
        ("UIRender/panelController_constructsMaskedHostingPanel", panelControllerConstructs),
        ("UIRender/panelController_permissionChangeReflowsFooter", panelControllerPermissionChangeReflowsFooter),
        ("UIRender/appDelegate_wiresVisibleItemCountReflow", appDelegateWiresVisibleItemCountReflow),
        ("UIRender/panelController_selectorWidthChangeInvalidatesCachedLayout", panelControllerSelectorWidthChangeInvalidatesCachedLayout)
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
    static func applicationFallbackRendersAsIconOnlyTile() async throws {
        let previousLanguage = LocalizationState.selection
        LocalizationState.selection = .finnish
        defer { LocalizationState.selection = previousLanguage }

        let (store, catalog, _, _) = makeStore()
        let fallbackID = SyntheticApplicationID.make(
            pid: 200,
            bundleIdentifier: "com.example.app-only",
            appName: "Vain sovellus"
        )
        let fallback = WindowItem(
            windowID: fallbackID,
            pid: 200,
            appName: "Vain sovellus",
            title: "",
            bounds: CGRect(x: 0, y: 0, width: 640, height: 400),
            isFrontmostApp: false,
            isMinimized: false,
            canCapturePreview: false,
            isTitleRedacted: false,
            preview: nil,
            icon: makeRenderPreview(color: .systemPurple, label: "S"),
            bundleIdentifier: "com.example.app-only",
            windowOwnerPID: nil
        )
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, appName: "Ikkuna", title: "Dokumentti", isFrontmostApp: true)
                .withPreview(makeRenderPreview(color: .systemTeal, label: "I")),
            fallback
        ]
        await openSwitcher(store)

        let layout = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            tileMinWidth: SwitchBladeSettings.shared.tileMinWidth,
            itemCount: store.items.count,
            tileAspectRatio: SwitcherLayout.tileAspectRatio
        ))
        store.updatePanelLayout(columns: layout.columns, tileWidth: layout.tileWidth)
        let host = NSHostingView(rootView: SwitcherView(store: store))
        host.frame = CGRect(origin: .zero, size: layout.panelFrame.size)
        host.layoutSubtreeIfNeeded()

        try expect(store.items.contains(where: { $0.id == fallbackID && $0.preview == nil }))
        try expectGreaterThan(host.fittingSize.width, CGFloat(0))
        try expectGreaterThan(host.fittingSize.height, CGFloat(0))
        try writeRenderArtifactIfRequested(host, name: "switcher-application-fallback")
    }

    @MainActor
    static func minimizedMergeReflowsAndRendersThirteenthItem() async throws {
        let previousLanguage = LocalizationState.selection
        let settings = SwitchBladeSettings.shared
        let previousTileWidth = settings.tileMinWidth
        let previousSelectorWidth = settings.selectorWidthFraction
        LocalizationState.selection = .english
        settings.tileMinWidth = 300
        settings.selectorWidthFraction = 0.8
        defer {
            LocalizationState.selection = previousLanguage
            settings.tileMinWidth = previousTileWidth
            settings.selectorWidthFraction = previousSelectorWidth
        }

        let colors: [NSColor] = [
            .systemIndigo, .systemTeal, .systemOrange, .systemPink,
            .systemBlue, .systemGreen, .systemPurple
        ]
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = (1...12).map { index in
            makeItem(
                id: CGWindowID(index),
                appName: "App \(index)",
                title: "Window \(index)"
            ).withPreview(makeRenderPreview(
                color: colors[(index - 1) % colors.count],
                label: "\(index)"
            ))
        }
        let minimizedID = SyntheticWindowID.make(pid: 500, index: 0, title: "Window 13")
        catalog.minimizedItems = [makeItem(
            id: minimizedID,
            pid: 500,
            appName: "App 13",
            title: "Window 13",
            isMinimized: true,
            canCapturePreview: false
        )]
        catalog.minimizedSnapshotDelayNanoseconds = 120_000_000

        let controller = SwitcherPanelController(store: store)
        store.onShow = { [weak controller, weak store] in
            controller?.prepare(itemCount: store?.items.count ?? 0)
        }
        store.onVisibleItemCountChanged = { [weak controller] itemCount in
            controller?.prepare(itemCount: itemCount)
        }
        await openSwitcher(store)
        try expectEqual(store.items.count, 12)
        let initialFrame = controller.constructionProbe.panelFrame

        for _ in 0 ..< 60 where !store.items.contains(where: { $0.id == minimizedID }) {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        try expectEqual(store.items.count, 13)
        let reflowedFrame = controller.constructionProbe.panelFrame
        try expectGreaterThan(
            reflowedFrame.height,
            initialFrame.height,
            "the panel must grow when the delayed minimized item creates a new row"
        )

        // Render the reported item count at the actual main-display scale and
        // confirm the delayed item is visible in a balanced 5 + 5 + 3 grid.
        let layout = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: CGRect(x: 0, y: 0, width: 2_560, height: 1_410),
            tileMinWidth: settings.tileMinWidth,
            itemCount: store.items.count,
            tileAspectRatio: SwitcherLayout.tileAspectRatio,
            selectorWidthFraction: settings.selectorWidthFraction
        ))
        store.updatePanelLayout(columns: layout.columns, tileWidth: layout.tileWidth)

        try expectEqual(layout.columns, 5)
        try expectEqual(layout.rows, 3)
        let host = NSHostingView(rootView: SwitcherView(store: store))
        host.frame = CGRect(origin: .zero, size: layout.panelFrame.size)
        host.layoutSubtreeIfNeeded()

        try expectGreaterThan(host.fittingSize.width, CGFloat(0))
        try expectGreaterThan(host.fittingSize.height, CGFloat(0))
        try writeRenderArtifactIfRequested(host, name: "switcher-thirteen-after-minimized-merge")
    }

    @MainActor
    static func fifteenItemsRenderAsBalancedThreeRows() async throws {
        let previousLanguage = LocalizationState.selection
        LocalizationState.selection = .english
        defer { LocalizationState.selection = previousLanguage }

        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = (1...15).map { index in
            makeItem(
                id: CGWindowID(index),
                appName: "App \(index)",
                title: "Window \(index)"
            ).withPreview(makeRenderPreview(
                color: index.isMultiple(of: 2) ? .systemIndigo : .systemTeal,
                label: "\(index)"
            ))
        }
        await openSwitcher(store)

        let layout = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: CGRect(x: 0, y: 0, width: 2_560, height: 1_410),
            tileMinWidth: 300,
            itemCount: store.items.count,
            tileAspectRatio: SwitcherLayout.tileAspectRatio,
            selectorWidthFraction: 0.9
        ))
        try expectEqual(layout.columns, 5)
        try expectEqual(layout.rows, 3)
        try expectEqual(layout.tileWidth, 300)
        store.updatePanelLayout(columns: layout.columns, tileWidth: layout.tileWidth)

        let host = NSHostingView(rootView: SwitcherView(store: store))
        host.frame = CGRect(origin: .zero, size: layout.panelFrame.size)
        host.layoutSubtreeIfNeeded()

        try expectGreaterThan(host.fittingSize.width, CGFloat(0))
        try expectGreaterThan(host.fittingSize.height, CGFloat(0))
        try writeRenderArtifactIfRequested(host, name: "switcher-fifteen-balanced")
    }

    @MainActor
    static func switcherColumnsRemainFixedAtPanelTileWidth() throws {
        let columns = SwitcherView.gridColumns(tileWidth: 173, count: 3)
        try expectEqual(columns.count, 3)
        for column in columns {
            switch column.size {
            case .fixed(let width):
                try expectEqual(width, 173)
            default:
                try expect(false, "switcher grid columns must remain fixed-width")
            }
            try expectEqual(column.spacing, SwitcherLayoutCalculator.gap)
        }
    }

    @MainActor
    static func switcherViewWiresFixedColumnContract() throws {
        let source = try productionSource("SwitcherView.swift")
        try expect(
            source.contains("Self.gridColumns(tileWidth: store.panelTileWidth, count: store.panelColumnCount)"),
            "SwitcherView must wire the rendered grid through the tested fixed-column contract"
        )
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
        // Keep the Finnish artifact tall enough to include the lower appearance
        // controls, where layout regressions in slider labels and values occur.
        finnishHost.frame = CGRect(x: 0, y: 0, width: 600, height: 1_700)
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
    static func objectSelectorWidthBindingUpdatesOnlySelectorWidth() throws {
        let settings = SwitchBladeSettings(
            userDefaults: makeIsolatedUserDefaults(),
            launchAtLoginController: LaunchAtLoginController.fake(currentStatus: .disabled)
        )
        settings.selectorWidthFraction = 0.8
        settings.highlightOpacity = 0.67

        let binding = SettingsView.objectSelectorWidthBinding(settings: settings)
        binding.wrappedValue = 0.55

        try expectEqual(settings.selectorWidthFraction, 0.55)
        try expectEqual(settings.highlightOpacity, 0.67)
    }

    @MainActor
    static func settingsViewWiresObjectSelectorBinding() throws {
        let source = try productionSource("SettingsView.swift")
        try expect(
            source.contains("value: Self.objectSelectorWidthBinding(settings: settings)"),
            "the object-selector slider must wire through its tested selector-width binding"
        )
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
    static func appDelegateWiresVisibleItemCountReflow() throws {
        let source = try productionSource("AppDelegate.swift")
        guard let callbackStart = source.range(of: "store.onVisibleItemCountChanged") else {
            try expect(false, "AppDelegate must connect visible item-count changes to panel sizing")
            return
        }
        let callbackBlock = String(source[callbackStart.lowerBound...].prefix(220))
        try expect(
            callbackBlock.contains("panelController?.prepare(itemCount: itemCount)"),
            "visible item-count changes must reflow the real panel controller"
        )
    }

    @MainActor
    static func panelControllerSelectorWidthChangeInvalidatesCachedLayout() throws {
        let settings = SwitchBladeSettings.shared
        let previousTileWidth = settings.tileMinWidth
        let previousSelectorWidth = settings.selectorWidthFraction
        defer {
            settings.tileMinWidth = previousTileWidth
            settings.selectorWidthFraction = previousSelectorWidth
        }

        settings.tileMinWidth = 140
        settings.selectorWidthFraction = 0.5
        let (store, _, _, _) = makeStore()
        let controller = SwitcherPanelController(store: store)
        controller.prepare(itemCount: 100)
        let narrowFrame = controller.constructionProbe.panelFrame

        try expectEqual(store.panelTileWidth, 140)
        try expectGreaterThan(store.panelColumnCount, 1)

        settings.selectorWidthFraction = 0.9
        controller.prepare(itemCount: 100)
        let wideFrame = controller.constructionProbe.panelFrame

        try expectGreaterThan(
            wideFrame.width,
            narrowFrame.width,
            "selector width change should invalidate the cached panel layout"
        )
        try expectEqual(store.panelTileWidth, 140)
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

    private static func productionSource(_ filename: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("SwitchBladeCore")
            .appendingPathComponent(filename)
        return try String(contentsOf: sourceURL, encoding: .utf8)
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
