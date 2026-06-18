import AppKit
import os.log
import QuartzCore
import SwiftUI

@MainActor
final class SwitcherPanelController {
    private let panel: SwitcherPanel
    private let hostingView: NSHostingView<SwitcherView>
    // CAShapeLayer mask is the only reliable way to get antialiased transparent
    // corners on macOS. clipShape/RoundedRectangle in SwiftUI uses a CGContext
    // software mask whose edges aren't composited cleanly against a clear window.
    private let cardMaskLayer = CAShapeLayer()

    // Card insets come from the shared layout calculator so the mask, the panel
    // size math, and SwitcherView padding all use the same numbers.
    private let cardMarginX = SwitcherLayoutCalculator.cardMarginX
    private let cardMarginY = SwitcherLayoutCalculator.cardMarginY
    private let cardCornerRadius: CGFloat = 20
    private struct CachedPanelLayout {
        let itemCount: Int
        let screenFrame: CGRect
        let visibleFrame: CGRect
        let tileMinWidth: CGFloat
        let tileAspectRatio: CGFloat
        let panelFrame: CGRect

        func matches(
            itemCount: Int,
            mouseLocation: CGPoint,
            tileMinWidth: CGFloat,
            tileAspectRatio: CGFloat
        ) -> Bool {
            self.itemCount == itemCount
                && screenFrame.contains(mouseLocation)
                && abs(self.tileMinWidth - tileMinWidth) < 0.5
                && abs(self.tileAspectRatio - tileAspectRatio) < 0.001
        }
    }

    private struct PanelSizingMetrics {
        let totalMs: Double
        let screenMs: Double
        let calcMs: Double
        let setFrameMs: Double
        let maskMs: Double
        let cacheHit: Bool
    }

    private var cachedLayout: CachedPanelLayout?

    /// Set by the owner (AppDelegate) so the store can cancel without this class
    /// needing a direct store reference.
    var onClickOutside: (() -> Void)? {
        didSet { clickMonitor.onClickOutside = onClickOutside }
    }
    private let clickMonitor: ClickOutsideMonitor
    private var keyWindowVerificationTask: Task<Void, Never>?

#if DEBUG
    /// Test-only view into the constructed panel so the AppKit wiring (masked
    /// hosting content view, transparency, window level) can be asserted without
    /// exposing internals. Excluded from the shipped app — `build-app.sh` builds
    /// `-c release`, where DEBUG is undefined.
    struct ConstructionProbe {
        let contentViewIsHostingView: Bool
        let hasCardMask: Bool
        let panelLevel: NSWindow.Level
        let panelIsOpaque: Bool
    }

    var constructionProbe: ConstructionProbe {
        ConstructionProbe(
            contentViewIsHostingView: panel.contentView === hostingView,
            hasCardMask: hostingView.layer?.mask === cardMaskLayer,
            panelLevel: panel.level,
            panelIsOpaque: panel.isOpaque
        )
    }
#endif

    init(store: SwitcherStore) {
        panel = SwitcherPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 1200, height: 800)),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.level = .statusBar
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        hostingView = NSHostingView(rootView: SwitcherView(store: store))
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = .clear
        // CAShapeLayer mask: GPU-composited, properly antialiased alpha at edges.
        // allowsEdgeAntialiasing = true ensures the mask edge is subpixel-smooth.
        // Updated in sizeAndCenter every time the panel is resized.
        cardMaskLayer.allowsEdgeAntialiasing = true
        hostingView.layer?.mask = cardMaskLayer
        panel.contentView = hostingView

        // Card frame provider closes over `panel` and the margin constants so
        // ClickOutsideMonitor can ask for an up-to-date rect after resize.
        let cardMarginX = self.cardMarginX
        let cardMarginY = self.cardMarginY
        let panelRef = panel
        clickMonitor = ClickOutsideMonitor(panel: panel) {
            CGRect(
                x: cardMarginX,
                y: cardMarginY,
                width: panelRef.frame.width - cardMarginX * 2,
                height: panelRef.frame.height - cardMarginY * 2
            )
        }

        // Force SwiftUI to build the initial view tree off-screen so the first
        // user-visible show isn't paying the ~30–100ms first-render cost.
        hostingView.layoutSubtreeIfNeeded()
    }

    func show(itemCount: Int) {
        let start = Date()
        let sizing = sizeAndCenter(itemCount: itemCount)
        // Ensure SwiftUI has laid out the current store state before the
        // transparent panel becomes visible.
        let layoutStart = Date()
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        let layoutEnd = Date()
        let orderStart = Date()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.alphaValue = 1
        hostingView.layer?.opacity = 1
        cardMaskLayer.opacity = 1
        CATransaction.commit()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        clickMonitor.start()
        let orderEnd = Date()

        scheduleKeyWindowVerification()

        let ms = Date().timeIntervalSince(start) * 1000
        let layoutMs = layoutEnd.timeIntervalSince(layoutStart) * 1000
        let orderMs = orderEnd.timeIntervalSince(orderStart) * 1000
        PerformanceDiagnostics.record(
            "panel_show",
            fields: [
                "item_count": .int(itemCount),
                "layout_ms": .double(layoutMs),
                "milliseconds": .double(ms),
                "order_ms": .double(orderMs),
                "size_cache_hit": .bool(sizing.cacheHit),
                "size_calc_ms": .double(sizing.calcMs),
                "size_mask_ms": .double(sizing.maskMs),
                "size_ms": .double(sizing.totalMs),
                "size_screen_ms": .double(sizing.screenMs),
                "size_set_frame_ms": .double(sizing.setFrameMs)
            ]
        )
        Logger.switcher.notice(
            "Panel show: \(ms, format: .fixed(precision: 1), privacy: .public) ms for \(itemCount, privacy: .public) items; size=\(sizing.totalMs, format: .fixed(precision: 1), privacy: .public), sizeCache=\(sizing.cacheHit, privacy: .public), layout=\(layoutMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public)"
        )
    }

    func invalidateLayoutCache(reason: String) {
        cachedLayout = nil
        Logger.switcher.info("Panel layout cache invalidated: \(reason, privacy: .public)")
    }

    /// macOS sometimes returns from `NSApp.activate` + `makeKeyAndOrderFront`
    /// without actually granting key-window status to an accessory app — most
    /// often after a long idle pause when the previously-frontmost app refuses
    /// to yield. The panel renders on screen but local NSEvent monitors
    /// (Enter, arrow keys, NSTrackingArea hover) never fire because they
    /// require key-window status, while the global CGEventTap for Cmd+Tab
    /// keeps working. Result: list cycles but selection cannot be committed.
    ///
    /// Retry the activation once if the panel is not key after 150 ms. Log
    /// both outcomes so we can confirm whether this path is hit in real
    /// reports.
    private func scheduleKeyWindowVerification() {
        keyWindowVerificationTask?.cancel()
        keyWindowVerificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, self.panel.isVisible else { return }
            if self.panel.isKeyWindow { return }

            Logger.switcher.notice(
                "Panel not key after show — retrying activation (likely accessory-activation stall after idle)"
            )
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)

            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, self.panel.isVisible else { return }
            if !self.panel.isKeyWindow {
                Logger.switcher.notice(
                    "Panel still not key after retry — local input (Enter, hover, click) may be lost until macOS reassigns key status"
                )
            }
        }
    }

    func hide() {
        keyWindowVerificationTask?.cancel()
        keyWindowVerificationTask = nil
        let start = Date()
        clickMonitor.stop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.alphaValue = 0
        hostingView.layer?.opacity = 0
        cardMaskLayer.opacity = 0
        CATransaction.commit()
        panel.orderOut(nil)
        CATransaction.flush()

        let ms = Date().timeIntervalSince(start) * 1000
        if ms > 20 {
            Logger.switcher.notice(
                "Panel hide slow: \(ms, format: .fixed(precision: 1), privacy: .public) ms"
            )
        }
    }

    private func sizeAndCenter(itemCount: Int) -> PanelSizingMetrics {
        let start = Date()
        let tileMinWidth = SwitchBladeSettings.shared.tileMinWidth
        let tileAspectRatio = SwitcherLayout.tileAspectRatio
        let mouseLocation = NSEvent.mouseLocation

        if let cachedLayout,
           cachedLayout.matches(
               itemCount: itemCount,
               mouseLocation: mouseLocation,
               tileMinWidth: tileMinWidth,
               tileAspectRatio: tileAspectRatio
           ),
           framesApproximatelyEqual(panel.frame, cachedLayout.panelFrame) {
            return PanelSizingMetrics(
                totalMs: Date().timeIntervalSince(start) * 1000,
                screenMs: 0,
                calcMs: 0,
                setFrameMs: 0,
                maskMs: 0,
                cacheHit: true
            )
        }

        let screenStart = Date()
        let geometry = cachedLayout.flatMap { cached -> (screenFrame: CGRect, visibleFrame: CGRect)? in
            guard cached.screenFrame.contains(mouseLocation) else { return nil }
            return (cached.screenFrame, cached.visibleFrame)
        } ?? activeScreenGeometry()
        let screenMs = Date().timeIntervalSince(screenStart) * 1000
        guard let geometry else {
            return PanelSizingMetrics(
                totalMs: Date().timeIntervalSince(start) * 1000,
                screenMs: screenMs,
                calcMs: 0,
                setFrameMs: 0,
                maskMs: 0,
                cacheHit: false
            )
        }

        let calcStart = Date()
        let result = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: geometry.visibleFrame,
            tileMinWidth: tileMinWidth,
            itemCount: itemCount,
            tileAspectRatio: tileAspectRatio
        ))
        let calcMs = Date().timeIntervalSince(calcStart) * 1000

        let setFrameStart = Date()
        if !framesApproximatelyEqual(panel.frame, result.panelFrame) {
            panel.setFrame(result.panelFrame, display: false)
        }
        let setFrameMs = Date().timeIntervalSince(setFrameStart) * 1000

        let maskStart = Date()
        updateCardMask(panelWidth: result.panelFrame.width,
                       panelHeight: result.panelFrame.height)
        let maskMs = Date().timeIntervalSince(maskStart) * 1000

        cachedLayout = CachedPanelLayout(
            itemCount: itemCount,
            screenFrame: geometry.screenFrame,
            visibleFrame: geometry.visibleFrame,
            tileMinWidth: tileMinWidth,
            tileAspectRatio: tileAspectRatio,
            panelFrame: result.panelFrame
        )

        return PanelSizingMetrics(
            totalMs: Date().timeIntervalSince(start) * 1000,
            screenMs: screenMs,
            calcMs: calcMs,
            setFrameMs: setFrameMs,
            maskMs: maskMs,
            cacheHit: false
        )
    }

    /// Screen the panel should appear on. Priority:
    /// 1. The screen currently containing the mouse cursor — matches user
    ///    intent when they trigger Cmd+Tab while looking at a secondary display.
    /// 2. NSApp.keyWindow's screen — fallback when the cursor is off-screen.
    /// 3. NSScreen.main — last resort.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return hit
        }
        if let keyScreen = NSApp.keyWindow?.screen {
            return keyScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func activeScreenGeometry() -> (screenFrame: CGRect, visibleFrame: CGRect)? {
        activeScreen().map { ($0.frame, $0.visibleFrame) }
    }

    private func framesApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5
            && abs(lhs.origin.y - rhs.origin.y) < 0.5
            && abs(lhs.size.width - rhs.size.width) < 0.5
            && abs(lhs.size.height - rhs.size.height) < 0.5
    }

    /// Keeps the CAShapeLayer mask in sync with the panel size.
    /// The card rect is the panel bounds inset by cardMarginX/Y.
    private func updateCardMask(panelWidth: CGFloat, panelHeight: CGFloat) {
        let cardRect = CGRect(
            x: cardMarginX,
            y: cardMarginY,
            width: panelWidth  - cardMarginX * 2,
            height: panelHeight - cardMarginY * 2
        )
        cardMaskLayer.frame = CGRect(origin: .zero,
                                     size: CGSize(width: panelWidth, height: panelHeight))
        cardMaskLayer.path = CGPath(roundedRect: cardRect,
                                    cornerWidth: cardCornerRadius,
                                    cornerHeight: cardCornerRadius,
                                    transform: nil)
    }
}

private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
