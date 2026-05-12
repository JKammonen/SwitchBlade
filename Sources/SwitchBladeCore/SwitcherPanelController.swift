import AppKit
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

    // Click-outside dismissal. Set by the owner (AppDelegate) so the store can
    // cancel without this class needing a direct reference to it.
    var onClickOutside: (() -> Void)?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

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

        // Force SwiftUI to build the initial view tree off-screen so the first
        // user-visible show isn't paying the ~30–100ms first-render cost.
        hostingView.layoutSubtreeIfNeeded()
    }

    func show(itemCount: Int) {
        sizeAndCenter(itemCount: itemCount)
        panel.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installClickMonitors()
    }

    func hide() {
        removeClickMonitors()
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    // MARK: - Click outside

    private func installClickMonitors() {
        guard globalClickMonitor == nil else { return }
        // Global: clicks anywhere outside our app — switching apps, clicking
        // the desktop, etc. NSEvent mouse-event monitors don't require an
        // Accessibility grant (only keyboard events do).
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.onClickOutside?()
        }
        // Local: clicks inside our panel window — dismiss only when the click
        // lands in the transparent margin around the card. Inside the card the
        // event passes through to the tile gesture recognizers.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if self.isClickInsideCard(event) { return event }
            self.onClickOutside?()
            return nil
        }
    }

    private func removeClickMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    /// True when `event.locationInWindow` falls inside the rounded-card region.
    /// Used to distinguish click-on-tile from click-on-padding.
    private func isClickInsideCard(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let point = event.locationInWindow
        let cardRect = CGRect(
            x: cardMarginX,
            y: cardMarginY,
            width: panel.frame.width - cardMarginX * 2,
            height: panel.frame.height - cardMarginY * 2
        )
        return cardRect.contains(point)
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

        panel.setFrame(result.panelFrame, display: true)
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
