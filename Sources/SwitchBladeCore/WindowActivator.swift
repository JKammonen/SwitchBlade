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

    struct WindowMatchDecision: Equatable {
        let index: Int
        let reason: String
        let titleMatchCount: Int
        let frameMatchCount: Int
        let frameDistanceBucket: String
        let chosenIsMain: Bool
        let chosenIsFocused: Bool
    }

    private struct MatchedWindow {
        let element: AXUIElement
        let decision: WindowMatchDecision
        let candidateCount: Int
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
        guard let match = matchingWindow(for: appElement, item: item) else {
            return false
        }
        let window = match.element

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

        let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let mainResult = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focusResult = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let activated = Self.shouldActivateApplication(afterTargeting: item)
            ? performApplicationActivation(pid: item.pid)
            : false
        logMatchDecision(
            action: "snap",
            item: item,
            match: match,
            raiseResult: raiseResult,
            mainResult: mainResult,
            focusResult: focusResult
        )
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
        let matchStart = Date()
        guard let match = matchingWindow(
            for: appElement,
            item: item,
            preferNonMainOnTies: item.isFrontmostApp
        ) else {
            let matchMs = Date().timeIntervalSince(matchStart) * 1000
            PerformanceDiagnostics.record(
                "activation_ax_match",
                fields: [
                    "matched": .bool(false),
                    "match_ms": .double(matchMs),
                    "pid": .int(Int(item.pid)),
                    "window_id": .int(Int(item.id))
                ]
            )
            Logger.activator.notice(
                "AX match failed pid=\(item.pid, privacy: .public) windowID=\(item.id, privacy: .public) matchMs=\(matchMs, format: .fixed(precision: 1), privacy: .public)"
            )
            return false
        }
        let matchMs = Date().timeIntervalSince(matchStart) * 1000
        let window = match.element

        var unminimizeResult: AXError?
        var unminimizeMs: Double?
        if item.isMinimized {
            let start = Date()
            unminimizeResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            unminimizeMs = Date().timeIntervalSince(start) * 1000
        }
        let raiseStart = Date()
        let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let raiseMs = Date().timeIntervalSince(raiseStart) * 1000
        let mainStart = Date()
        let mainResult = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let mainMs = Date().timeIntervalSince(mainStart) * 1000
        let focusStart = Date()
        let focusResult = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let focusMs = Date().timeIntervalSince(focusStart) * 1000
        PerformanceDiagnostics.record(
            "activation_ax_target",
            fields: [
                "candidate_count": .int(match.candidateCount),
                "focus_ms": .double(focusMs),
                "focus_result": .int(Int(focusResult.rawValue)),
                "main_ms": .double(mainMs),
                "main_result": .int(Int(mainResult.rawValue)),
                "match_ms": .double(matchMs),
                "pid": .int(Int(item.pid)),
                "raise_ms": .double(raiseMs),
                "raise_result": .int(Int(raiseResult.rawValue)),
                "unminimize_ms": .double(unminimizeMs ?? 0),
                "unminimize_result": .int(Int(unminimizeResult?.rawValue ?? Int32.min)),
                "window_id": .int(Int(item.id))
            ]
        )
        logMatchDecision(
            action: "activate",
            item: item,
            match: match,
            raiseResult: raiseResult,
            mainResult: mainResult,
            focusResult: focusResult,
            unminimizeResult: unminimizeResult
        )
        return raiseResult == .success && mainResult == .success && focusResult == .success
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

        let start = Date()
        let activated = app.activate(options: [])
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        PerformanceDiagnostics.record(
            "activation_app_activate",
            fields: [
                "activated": .bool(activated),
                "app_activate_ms": .double(elapsedMs),
                "pid": .int(Int(pid))
            ]
        )
        Logger.activator.info(
            "App activate timing pid=\(pid, privacy: .public) activated=\(activated, privacy: .public) elapsed=\(elapsedMs, format: .fixed(precision: 1), privacy: .public)ms"
        )
        return activated
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
        guard let match = matchingWindow(for: appElement, item: item) else {
            return false
        }

        return pressCloseButton(on: match.element)
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
    ) -> MatchedWindow? {
        let windowsStart = Date()
        guard let windows = windows(for: appElement) else {
            return nil
        }
        let windowsMs = Date().timeIntervalSince(windowsStart) * 1000

        let candidatesStart = Date()
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
        let candidatesMs = Date().timeIntervalSince(candidatesStart) * 1000

        let decisionStart = Date()
        if let decision = Self.bestMatchDecision(
            for: item,
            candidates: candidates.map(\.candidate),
            preferNonMainOnTies: preferNonMainOnTies
        ) {
            let decisionMs = Date().timeIntervalSince(decisionStart) * 1000
            PerformanceDiagnostics.record(
                "activation_ax_match",
                fields: [
                    "candidate_count": .int(candidates.count),
                    "candidates_ms": .double(candidatesMs),
                    "decision_ms": .double(decisionMs),
                    "matched": .bool(true),
                    "pid": .int(Int(item.pid)),
                    "window_id": .int(Int(item.id)),
                    "windows_ms": .double(windowsMs)
                ]
            )
            return MatchedWindow(
                element: candidates[decision.index].element,
                decision: decision,
                candidateCount: candidates.count
            )
        }
        let decisionMs = Date().timeIntervalSince(decisionStart) * 1000

        let titleMatchCount = candidates.reduce(0) { count, candidate in
            count + (Self.titleMatches(item.title, candidateTitle: candidate.candidate.title) ? 1 : 0)
        }
        let frameMatchCount = candidates.reduce(0) { count, candidate in
            guard let frame = candidate.candidate.frame else { return count }
            return count + (Self.framesAreClose(frame, item.bounds) ? 1 : 0)
        }
        Logger.activator.notice(
            "AX no matching window pid=\(item.pid, privacy: .public) windowID=\(item.id, privacy: .public) appWindows=\(windows.count, privacy: .public) titleMatches=\(titleMatchCount, privacy: .public) frameMatches=\(frameMatchCount, privacy: .public) windowsMs=\(windowsMs, format: .fixed(precision: 1), privacy: .public) candidatesMs=\(candidatesMs, format: .fixed(precision: 1), privacy: .public) decisionMs=\(decisionMs, format: .fixed(precision: 1), privacy: .public)"
        )
        return nil
    }

    private func logMatchDecision(
        action: String,
        item: WindowItem,
        match: MatchedWindow,
        raiseResult: AXError,
        mainResult: AXError,
        focusResult: AXError,
        unminimizeResult: AXError? = nil
    ) {
        let unminimizeRaw = unminimizeResult?.rawValue ?? Int32.min
        Logger.activator.info(
            "AX target action=\(action, privacy: .public) pid=\(item.pid, privacy: .public) windowID=\(item.id, privacy: .public) candidates=\(match.candidateCount, privacy: .public) chosenIndex=\(match.decision.index, privacy: .public) reason=\(match.decision.reason, privacy: .public) titleMatches=\(match.decision.titleMatchCount, privacy: .public) frameMatches=\(match.decision.frameMatchCount, privacy: .public) frameDistance=\(match.decision.frameDistanceBucket, privacy: .public) chosenMain=\(match.decision.chosenIsMain, privacy: .public) chosenFocused=\(match.decision.chosenIsFocused, privacy: .public) raiseResult=\(raiseResult.rawValue, privacy: .public) mainResult=\(mainResult.rawValue, privacy: .public) focusResult=\(focusResult.rawValue, privacy: .public) unminimizeResult=\(unminimizeRaw, privacy: .public)"
        )
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
        bestMatchDecision(
            for: item,
            candidates: candidates,
            preferNonMainOnTies: preferNonMainOnTies
        )?.index
    }

    static func bestMatchDecision(
        for item: WindowItem,
        candidates: [WindowMatchCandidate],
        preferNonMainOnTies: Bool = false
    ) -> WindowMatchDecision? {
        guard !candidates.isEmpty else { return nil }

        let indexedCandidates = candidates.enumerated().map { (index: $0.offset, candidate: $0.element) }
        let exactTitleMatches = indexedCandidates.filter {
            titleMatches(item.title, candidateTitle: $0.candidate.title)
        }
        let titleFiltered = exactTitleMatches.isEmpty ? indexedCandidates : exactTitleMatches

        let exactFrameMatches = titleFiltered.filter { indexedCandidate in
            guard let frame = indexedCandidate.candidate.frame else { return false }
            return framesAreClose(frame, item.bounds)
        }
        if let bestFrameMatch = bestFrameCandidate(
            in: exactFrameMatches,
            for: item,
            preferNonMainOnTies: preferNonMainOnTies
        ) {
            return decision(
                bestFrameMatch,
                reason: "frame-close",
                item: item,
                titleMatchCount: exactTitleMatches.count,
                frameMatchCount: exactFrameMatches.count
            )
        }

        let frameFallbackCandidates = titleFiltered.filter { $0.candidate.frame != nil }
        if let bestFrameFallback = bestFrameCandidate(
            in: frameFallbackCandidates,
            for: item,
            preferNonMainOnTies: preferNonMainOnTies
        ) {
            return decision(
                bestFrameFallback,
                reason: exactTitleMatches.isEmpty ? "closest-frame-no-title" : "closest-frame",
                item: item,
                titleMatchCount: exactTitleMatches.count,
                frameMatchCount: exactFrameMatches.count
            )
        }

        guard let fallback = bestFallbackCandidate(
            in: titleFiltered,
            for: item,
            preferNonMainOnTies: preferNonMainOnTies
        ) else { return nil }
        return decision(
            fallback,
            reason: exactTitleMatches.isEmpty ? "fallback-no-title" : "fallback-title",
            item: item,
            titleMatchCount: exactTitleMatches.count,
            frameMatchCount: exactFrameMatches.count
        )
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

    private static func frameDistanceBucket(_ distance: CGFloat?) -> String {
        guard let distance else { return "none" }
        switch distance {
        case ..<12:
            return "lt12"
        case ..<50:
            return "lt50"
        case ..<200:
            return "lt200"
        default:
            return "gte200"
        }
    }

    private static func decision(
        _ match: (index: Int, candidate: WindowMatchCandidate),
        reason: String,
        item: WindowItem,
        titleMatchCount: Int,
        frameMatchCount: Int
    ) -> WindowMatchDecision {
        let distance = match.candidate.frame.map { frameDistance($0, item.bounds) }
        return WindowMatchDecision(
            index: match.index,
            reason: reason,
            titleMatchCount: titleMatchCount,
            frameMatchCount: frameMatchCount,
            frameDistanceBucket: frameDistanceBucket(distance),
            chosenIsMain: match.candidate.isMain,
            chosenIsFocused: match.candidate.isFocused
        )
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
