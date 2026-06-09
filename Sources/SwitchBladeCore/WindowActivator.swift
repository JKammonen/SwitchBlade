import AppKit
import ApplicationServices
import os.log

final class WindowActivator: WindowActivating, @unchecked Sendable {
    struct ScreenGeometry: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    struct WindowMatchCandidate: Equatable {
        let title: String?
        let frame: CGRect?
        let isMain: Bool
        let isFocused: Bool
    }

    private let raiseWindowOverride: ((WindowItem) -> Bool)?
    private let activateApplicationOverride: ((pid_t) -> Bool)?

    init(
        raiseWindowOverride: ((WindowItem) -> Bool)? = nil,
        activateApplicationOverride: ((pid_t) -> Bool)? = nil
    ) {
        self.raiseWindowOverride = raiseWindowOverride
        self.activateApplicationOverride = activateApplicationOverride
    }

    func activate(_ item: WindowItem) {
        log(action: "activate", item: item)
        // Select the target window first, then activate the app. AX raise/focus
        // alone does not make many apps frontmost, while app activation before
        // AX targeting can raise the app's previously-main sibling window.
        let raised = raiseWindow(item)
        let activated = Self.shouldActivateApplication(afterTargeting: item)
            ? performApplicationActivation(pid: item.pid)
            : false
        Logger.activator.info(
            "activate result pid=\(item.pid, privacy: .public) windowID=\(item.id, privacy: .public) raised=\(raised, privacy: .public) appActivated=\(activated, privacy: .public)"
        )
    }

    func activateApplication(pid: pid_t) {
        Logger.activator.info("activate app pid=\(pid, privacy: .public)")
        let activated = performApplicationActivation(pid: pid)
        Logger.activator.info("activate app result pid=\(pid, privacy: .public) appActivated=\(activated, privacy: .public)")
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

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let activated = Self.shouldActivateApplication(afterTargeting: item)
            ? performApplicationActivation(pid: item.pid)
            : false
        Logger.activator.info(
            "snap result pid=\(item.pid, privacy: .public) windowID=\(item.id, privacy: .public) appActivated=\(activated, privacy: .public)"
        )
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

    @discardableResult
    private func raiseMatchingWindow(_ item: WindowItem) -> Bool {
        let appElement = AXUIElementCreateApplication(item.pid)
        guard let window = matchingWindow(
            for: appElement,
            item: item,
            preferNonMainOnTies: item.isFrontmostApp
        ) else {
            Logger.activator.notice(
                "AX match failed pid=\(item.pid, privacy: .public) windowID=\(item.id, privacy: .public)"
            )
            return false
        }

        if item.isMinimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    @discardableResult
    private func raiseWindow(_ item: WindowItem) -> Bool {
        if let raiseWindowOverride {
            return raiseWindowOverride(item)
        }
        return raiseMatchingWindow(item)
    }

    @discardableResult
    private func activateRunningApplication(pid: pid_t) -> Bool {
        guard pid != getpid(),
              let app = NSRunningApplication(processIdentifier: pid) else {
            Logger.activator.notice("App activation unavailable pid=\(pid, privacy: .public)")
            return false
        }

        return app.activate(options: [])
    }

    @discardableResult
    private func performApplicationActivation(pid: pid_t) -> Bool {
        if let activateApplicationOverride {
            return activateApplicationOverride(pid)
        }
        return activateRunningApplication(pid: pid)
    }

    static func shouldActivateApplication(afterTargeting item: WindowItem) -> Bool {
        // Same-app window switches already target the frontmost app. Re-running
        // app activation there can hand focus back to the app's previously-main
        // sibling window and undo the AX-targeted selection we just made.
        return !item.isFrontmostApp
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
            Logger.activator.notice("AX windows fetch failed result=\(result.rawValue, privacy: .public)")
            return nil
        }

        return windows
    }

    private func matchingWindow(
        for appElement: AXUIElement,
        item: WindowItem,
        preferNonMainOnTies: Bool = false
    ) -> AXUIElement? {
        guard let windows = windows(for: appElement) else {
            return nil
        }

        let candidates = windows.map { window in
            (
                element: window,
                candidate: WindowMatchCandidate(
                    title: axString(kAXTitleAttribute, on: window),
                    frame: axFrame(on: window),
                    isMain: axBool(kAXMainAttribute, on: window),
                    isFocused: axBool(kAXFocusedAttribute, on: window)
                )
            )
        }

        if let matchIndex = Self.bestMatchIndex(
            for: item,
            candidates: candidates.map(\.candidate),
            preferNonMainOnTies: preferNonMainOnTies
        ) {
            return candidates[matchIndex].element
        }

        let titleMatchCount = candidates.reduce(0) { count, candidate in
            count + (Self.titleMatches(item.title, candidateTitle: candidate.candidate.title) ? 1 : 0)
        }
        let frameMatchCount = candidates.reduce(0) { count, candidate in
            guard let frame = candidate.candidate.frame else { return count }
            return count + (Self.framesAreClose(frame, item.bounds) ? 1 : 0)
        }
        Logger.activator.notice(
            "AX no matching window pid=\(item.pid, privacy: .public) windowID=\(item.id, privacy: .public) appWindows=\(windows.count, privacy: .public) titleMatches=\(titleMatchCount, privacy: .public) frameMatches=\(frameMatchCount, privacy: .public)"
        )
        return nil
    }

    private func axString(_ attribute: String, on element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }

        return rawValue as? String
    }

    private func axBool(_ attribute: String, on element: AXUIElement) -> Bool {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == CFBooleanGetTypeID() else {
            return false
        }

        return CFBooleanGetValue((rawValue as! CFBoolean))
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

    /// Internal so tests can verify the tolerance logic without going through
    /// a real AX walk.
    static func framesAreClose(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 12) -> Bool {
        return abs(lhs.origin.x - rhs.origin.x) < tolerance
            && abs(lhs.origin.y - rhs.origin.y) < tolerance
            && abs(lhs.width - rhs.width) < tolerance
            && abs(lhs.height - rhs.height) < tolerance
    }

    static func bestMatchIndex(
        for item: WindowItem,
        candidates: [WindowMatchCandidate],
        preferNonMainOnTies: Bool = false
    ) -> Int? {
        guard !candidates.isEmpty else { return nil }

        let indexedCandidates = candidates.enumerated().map { (index: $0.offset, candidate: $0.element) }
        let titleFiltered = {
            let exactTitleMatches = indexedCandidates.filter {
                titleMatches(item.title, candidateTitle: $0.candidate.title)
            }
            return exactTitleMatches.isEmpty ? indexedCandidates : exactTitleMatches
        }()

        let exactFrameMatches = titleFiltered.filter { indexedCandidate in
            guard let frame = indexedCandidate.candidate.frame else { return false }
            return framesAreClose(frame, item.bounds)
        }
        if let bestFrameMatch = bestFrameCandidate(
            in: exactFrameMatches,
            for: item,
            preferNonMainOnTies: preferNonMainOnTies
        ) {
            return bestFrameMatch.index
        }

        let frameFallbackCandidates = titleFiltered.filter { $0.candidate.frame != nil }
        if let bestFrameFallback = bestFrameCandidate(
            in: frameFallbackCandidates,
            for: item,
            preferNonMainOnTies: preferNonMainOnTies
        ) {
            return bestFrameFallback.index
        }

        return bestFallbackCandidate(
            in: titleFiltered,
            for: item,
            preferNonMainOnTies: preferNonMainOnTies
        )?.index
    }

    private static func bestFrameCandidate(
        in candidates: [(index: Int, candidate: WindowMatchCandidate)],
        for item: WindowItem,
        preferNonMainOnTies: Bool
    ) -> (index: Int, candidate: WindowMatchCandidate)? {
        guard !candidates.isEmpty else { return nil }

        return candidates.min { lhs, rhs in
            guard let lhsFrame = lhs.candidate.frame,
                  let rhsFrame = rhs.candidate.frame else {
                return lhs.index < rhs.index
            }

            let lhsDistance = frameDistance(lhsFrame, item.bounds)
            let rhsDistance = frameDistance(rhsFrame, item.bounds)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }

            return prefers(
                lhs.candidate,
                over: rhs.candidate,
                preferNonMainOnTies: preferNonMainOnTies,
                lhsIndex: lhs.index,
                rhsIndex: rhs.index
            )
        }
    }

    private static func bestFallbackCandidate(
        in candidates: [(index: Int, candidate: WindowMatchCandidate)],
        for item: WindowItem,
        preferNonMainOnTies: Bool
    ) -> (index: Int, candidate: WindowMatchCandidate)? {
        guard !candidates.isEmpty else { return nil }

        return candidates.min { lhs, rhs in
            prefers(
                lhs.candidate,
                over: rhs.candidate,
                preferNonMainOnTies: preferNonMainOnTies,
                lhsIndex: lhs.index,
                rhsIndex: rhs.index
            )
        }
    }

    private static func titleMatches(_ itemTitle: String, candidateTitle: String?) -> Bool {
        itemTitle.isEmpty || candidateTitle == itemTitle
    }

    private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.origin.x - rhs.origin.x)
            + abs(lhs.origin.y - rhs.origin.y)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    private static func prefers(
        _ lhs: WindowMatchCandidate,
        over rhs: WindowMatchCandidate,
        preferNonMainOnTies: Bool,
        lhsIndex: Int,
        rhsIndex: Int
    ) -> Bool {
        if preferNonMainOnTies {
            let lhsPenalty = currentWindowPenalty(lhs)
            let rhsPenalty = currentWindowPenalty(rhs)
            if lhsPenalty != rhsPenalty {
                return lhsPenalty < rhsPenalty
            }
        }

        return lhsIndex < rhsIndex
    }

    private static func currentWindowPenalty(_ candidate: WindowMatchCandidate) -> Int {
        (candidate.isMain ? 1 : 0) + (candidate.isFocused ? 1 : 0)
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
