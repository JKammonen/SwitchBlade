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

    // Mirror the card insets so the mask stays in sync with SwitcherView padding.
    private let cardMarginX: CGFloat = 20
    private let cardMarginY: CGFloat = 12
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
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        hostingView = NSHostingView(rootView: SwitcherView(store: store))
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = .clear
        // CAShapeLayer mask: GPU-composited, properly antialiased alpha at edges.
        // Updated in sizeAndCenter every time the panel is resized.
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

        let settings   = SwitchBladeSettings.shared
        let tileW      = settings.tileMinWidth
        let gap: CGFloat = 10
        let gridPadX: CGFloat = 14      // .padding(14)
        let gridPadY: CGFloat = 14 + 6  // .padding(14) + .padding(.vertical, 6)
        let verticalSafety: CGFloat = 4

        let maxWidth = min(frame.width - 40, 1400)
        let maxCardWidth = maxWidth - cardMarginX * 2
        let maxGridWidth = max(tileW, maxCardWidth - gridPadX * 2)

        // How many columns fit in the screen-wide layout — that's the upper bound.
        let maxColumns = max(1, Int((maxGridWidth + gap) / (tileW + gap)))

        // Shrink to actual item count so a 3-item panel doesn't reserve a 4th slot.
        let columns = max(1, min(maxColumns, itemCount))
        let rows    = max(1, Int(ceil(Double(itemCount) / Double(columns))))

        // Per-tile width computed against the wide grid, but applied to the actual
        // column count so visual tile size stays consistent regardless of item count.
        let columnW = (maxGridWidth - CGFloat(maxColumns - 1) * gap) / CGFloat(maxColumns)
        let tileH   = columnW / SwitcherLayout.tileAspectRatio

        let gridWidth = CGFloat(columns) * columnW + CGFloat(columns - 1) * gap
        let gridH     = CGFloat(rows) * tileH + CGFloat(rows - 1) * gap + gridPadY * 2
        let cardH     = min(gridH, frame.height * 0.80)
        let height    = cardH + cardMarginY * 2 + verticalSafety
        let width     = gridWidth + gridPadX * 2 + cardMarginX * 2

        let origin = CGPoint(x: frame.midX - width / 2,
                             y: frame.midY - height / 2)
        panel.setFrame(CGRect(origin: origin,
                              size: CGSize(width: width, height: height)),
                       display: true)

        updateCardMask(panelWidth: width, panelHeight: height)
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
