import AppKit
import ApplicationServices
import os.log

final class WindowActivator: WindowActivating, Sendable {
    struct ScreenGeometry: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    func activate(_ item: WindowItem) {
        log(action: "activate", item: item)
        NSRunningApplication(processIdentifier: item.pid)?.activate(options: [])
        // raiseMatchingWindow must run on the main thread: kAXRaiseAction internally
        // calls makeKeyAndOrderFront: which is AppKit-main-thread-only. Running it
        // off-thread causes EXC_BREAKPOINT ("Must only be used from the main thread").
        // The panel is already dismissed before this point because commitSelection()
        // defers the entire activate() call past one RunLoop cycle (Task @MainActor).
        raiseMatchingWindow(item)
    }

    func activateApplication(pid: pid_t) {
        guard pid != getpid() else { return }
        Logger.activator.info("activate app pid=\(pid, privacy: .public)")
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    func snap(_ item: WindowItem, to edge: WindowSnapEdge) -> Bool {
        log(action: "snap \(edge.rawValue)", item: item)

        let appElement = AXUIElementCreateApplication(item.pid)
        guard let window = matchingWindow(for: appElement, item: item) else {
            return false
        }

        if item.isMinimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        let currentFrame = axFrame(on: window) ?? item.bounds
        let screenGeometries = NSScreen.screens.map {
            ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        guard let screen = Self.bestScreen(for: currentFrame, candidates: screenGeometries) else {
            return false
        }

        let targetFrame = Self.snapFrame(
            inVisibleFrame: screen.visibleFrame,
            screenFrame: screen.frame,
            to: edge
        )
        guard setFrame(targetFrame, on: window) else {
            return false
        }

        NSRunningApplication(processIdentifier: item.pid)?.activate(options: [])
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
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
        guard let window = matchingWindow(for: appElement, item: item) else {
            return
        }

        if item.isMinimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func closeMatchingWindow(_ item: WindowItem) -> Bool {
        let appElement = AXUIElementCreateApplication(item.pid)
        guard let window = matchingWindow(for: appElement, item: item) else {
            return false
        }

        return pressCloseButton(on: window)
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

    private func matchingWindow(for appElement: AXUIElement, item: WindowItem) -> AXUIElement? {
        guard let windows = windows(for: appElement) else {
            return nil
        }

        return windows.first(where: { matches($0, item: item) })
    }

    private func setFrame(_ frame: CGRect, on window: AXUIElement) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return positionResult == .success && sizeResult == .success
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

    static func snapFrame(inVisibleFrame visibleFrame: CGRect, screenFrame: CGRect, to edge: WindowSnapEdge) -> CGRect {
        let halfWidth = visibleFrame.width / 2
        let halfHeight = visibleFrame.height / 2
        let topY = screenFrame.maxY - visibleFrame.maxY
        let bottomY = topY + halfHeight

        switch edge {
        case .left:
            return CGRect(
                x: visibleFrame.minX,
                y: topY,
                width: halfWidth,
                height: visibleFrame.height
            )
        case .right:
            return CGRect(
                x: visibleFrame.midX,
                y: topY,
                width: halfWidth,
                height: visibleFrame.height
            )
        case .top:
            return CGRect(
                x: visibleFrame.minX,
                y: topY,
                width: visibleFrame.width,
                height: halfHeight
            )
        case .bottom:
            return CGRect(
                x: visibleFrame.minX,
                y: bottomY,
                width: visibleFrame.width,
                height: halfHeight
            )
        }
    }

    static func bestScreen(for windowFrame: CGRect, candidates: [ScreenGeometry]) -> ScreenGeometry? {
        guard !candidates.isEmpty else { return nil }

        let midpoint = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        var bestCandidate = candidates[0]
        var bestScore = intersectionArea(windowFrame, candidates[0].visibleFrame)

        for candidate in candidates.dropFirst() {
            let score = intersectionArea(windowFrame, candidate.visibleFrame)
            if score > bestScore {
                bestCandidate = candidate
                bestScore = score
            }
        }

        if bestScore > 0 {
            return bestCandidate
        }

        if let containing = candidates.first(where: { $0.visibleFrame.contains(midpoint) }) {
            return containing
        }

        return candidates.min {
            centerDistanceSquared(from: $0.visibleFrame, to: midpoint) < centerDistanceSquared(from: $1.visibleFrame, to: midpoint)
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func centerDistanceSquared(from rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return dx * dx + dy * dy
    }
}
