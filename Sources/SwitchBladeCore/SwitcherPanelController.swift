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
    }

    func hide() {
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    private func sizeAndCenter(itemCount: Int) {
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
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
