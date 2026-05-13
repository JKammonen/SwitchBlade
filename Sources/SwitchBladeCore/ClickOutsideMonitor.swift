import AppKit

/// Detects mouse-down events outside the visible card region of a panel and
/// invokes `onClickOutside`. Two monitors:
/// - Global: any click in another app or on the desktop.
/// - Local: click inside the panel window but in the transparent margin
///   around the card. Clicks inside the card pass through to SwiftUI gestures.
///
/// NSEvent mouse monitors don't require Accessibility permission (only
/// keyboard monitors do), so this is safe even when the app starts up with
/// only Screen Recording granted.
@MainActor
final class ClickOutsideMonitor {
    /// Returns the card frame in the panel's local coordinates; called every
    /// time a local click arrives so it stays correct across panel resizes.
    typealias CardFrameProvider = () -> CGRect

    var onClickOutside: (() -> Void)?

    private weak var panel: NSPanel?
    private let cardFrameProvider: CardFrameProvider
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(panel: NSPanel, cardFrame: @escaping CardFrameProvider) {
        self.panel = panel
        self.cardFrameProvider = cardFrame
    }

    func start() {
        // Reinstall both monitors together so we never end up in a half-installed
        // state where global fires but local doesn't (or vice versa).
        stop()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.onClickOutside?()
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if self.isClickInsideCard(event) { return event }
            self.onClickOutside?()
            return nil
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func isClickInsideCard(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel else { return false }
        return cardFrameProvider().contains(event.locationInWindow)
    }
}
