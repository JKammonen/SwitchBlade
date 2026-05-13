import AppKit
import ApplicationServices
import os.log

final class WindowActivator: WindowActivating, Sendable {
    func activate(_ item: WindowItem) {
        log(action: "activate", item: item)
        NSRunningApplication(processIdentifier: item.pid)?.activate(options: [.activateAllWindows])
        // raiseMatchingWindow must run on the main thread: kAXRaiseAction internally
        // calls makeKeyAndOrderFront: which is AppKit-main-thread-only. Running it
        // off-thread causes EXC_BREAKPOINT ("Must only be used from the main thread").
        // The panel is already dismissed before this point because commitSelection()
        // defers the entire activate() call past one RunLoop cycle (Task @MainActor).
        raiseMatchingWindow(item)
    }

    func close(_ item: WindowItem) {
        log(action: "close", item: item)
        // Only close the window via AX — never terminate the app process.
        _ = closeMatchingWindow(item)
    }

    func quit(_ item: WindowItem) {
        log(action: "quit", item: item)
        // Never quit SwitchBlade itself.
        guard item.pid != getpid() else { return }
        NSRunningApplication(processIdentifier: item.pid)?.terminate()
    }

    func hide(_ item: WindowItem) {
        log(action: "hide", item: item)
        guard item.pid != getpid() else { return }
        NSRunningApplication(processIdentifier: item.pid)?.hide()
    }

    /// One log helper for all four actions so the format stays consistent and
    /// we never accidentally log a pid without a title.
    private func log(action: String, item: WindowItem) {
        Logger.activator.info(
            "\(action, privacy: .public) pid=\(item.pid, privacy: .public) title=\(item.title, privacy: .private)"
        )
    }

    private func raiseMatchingWindow(_ item: WindowItem) {
        let appElement = AXUIElementCreateApplication(item.pid)
        guard let windows = windows(for: appElement) else {
            return
        }

        for window in windows where matches(window, item: item) {
            if item.isMinimized {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            break
        }
    }

    private func closeMatchingWindow(_ item: WindowItem) -> Bool {
        let appElement = AXUIElementCreateApplication(item.pid)
        guard let windows = windows(for: appElement) else {
            return false
        }

        for window in windows where matches(window, item: item) {
            if pressCloseButton(on: window) {
                return true
            }
        }

        return false
    }

    private func pressCloseButton(on window: AXUIElement) -> Bool {
        var closeButtonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonValue) == .success,
              let closeButtonValue,
              CFGetTypeID(closeButtonValue) == AXUIElementGetTypeID() else {
            return false
        }

        let closeButton = closeButtonValue as! AXUIElement

        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
    }

    private func windows(for appElement: AXUIElement) -> [AXUIElement]? {
        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue)
        guard result == .success, let windows = rawValue as? [AXUIElement] else {
            return nil
        }

        return windows
    }

    private func matches(_ window: AXUIElement, item: WindowItem) -> Bool {
        let titleMatches = item.title.isEmpty || axString(kAXTitleAttribute, on: window) == item.title

        guard titleMatches else {
            return false
        }

        if item.isMinimized {
            return true
        }

        guard let frame = axFrame(on: window) else {
            return item.title.isEmpty
        }

        return Self.framesAreClose(frame, item.bounds)
    }

    private func axString(_ attribute: String, on element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }

        return rawValue as? String
    }

    private func axFrame(on element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionAX, .cgPoint, &point)
        AXValueGetValue(sizeAX, .cgSize, &size)

        return CGRect(origin: point, size: size)
    }

    /// Internal so tests can verify the tolerance logic without going through
    /// a real AX walk.
    static func framesAreClose(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 12) -> Bool {
        return abs(lhs.origin.x - rhs.origin.x) < tolerance
            && abs(lhs.origin.y - rhs.origin.y) < tolerance
            && abs(lhs.width - rhs.width) < tolerance
            && abs(lhs.height - rhs.height) < tolerance
    }
}