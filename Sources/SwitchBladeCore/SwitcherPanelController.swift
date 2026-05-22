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

    /// Set by the owner (AppDelegate) so the store can cancel without this class
    /// needing a direct store reference.
    var onClickOutside: (() -> Void)? {
        didSet { clickMonitor.onClickOutside = onClickOutside }
    }
    private let clickMonitor: ClickOutsideMonitor
    private var keyWindowVerificationTask: Task<Void, Never>?

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
        let sizeStart = Date()
        sizeAndCenter(itemCount: itemCount)
        let sizeEnd = Date()
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
        let sizeMs = sizeEnd.timeIntervalSince(sizeStart) * 1000
        let layoutMs = layoutEnd.timeIntervalSince(layoutStart) * 1000
        let orderMs = orderEnd.timeIntervalSince(orderStart) * 1000
        Logger.switcher.notice(
            "Panel show: \(ms, format: .fixed(precision: 1), privacy: .public) ms for \(itemCount, privacy: .public) items; size=\(sizeMs, format: .fixed(precision: 1), privacy: .public), layout=\(layoutMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public)"
        )
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

    private func sizeAndCenter(itemCount: Int) {
        let targetScreen = activeScreen()
        guard let frame = targetScreen?.visibleFrame else { return }

        let result = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: frame,
            tileMinWidth: SwitchBladeSettings.shared.tileMinWidth,
            itemCount: itemCount,
            tileAspectRatio: SwitcherLayout.tileAspectRatio
        ))

        panel.setFrame(result.panelFrame, display: false)
        updateCardMask(panelWidth: result.panelFrame.width,
                       panelHeight: result.panelFrame.height)
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
