import AppKit
import ApplicationServices
import os.log

final class WindowActivator: WindowActivating, @unchecked Sendable {
    private static let axMessagingTimeoutSeconds: Float = 0.25
    private static let maximumAXCandidateWindows = 32
    private static let maximumAXCandidateScanSeconds: TimeInterval = 2.0
    private static let activationConfirmationAttempts = 100
    private static let activationConfirmationIntervalMicroseconds: useconds_t = 20_000

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

    private let raiseWindowOverride: ((WindowActionTarget) -> Bool)?
    private let activateApplicationOverride: ((pid_t) -> Bool)?

    init(
        raiseWindowOverride: ((WindowActionTarget) -> Bool)? = nil,
        activateApplicationOverride: ((pid_t) -> Bool)? = nil
    ) {
        self.raiseWindowOverride = raiseWindowOverride
        self.activateApplicationOverride = activateApplicationOverride
    }

    func activate(_ item: WindowActionTarget) -> Bool {
        log(action: "activate", item: item)
        // Select the target window first, then activate the app. AX raise/focus
        // alone does not make many apps frontmost, while app activation before
        // AX targeting can raise the app's previously-main sibling window.
        let raised = raiseWindow(item)
        let requiresApplicationActivation = Self.shouldActivateApplication(afterTargeting: item)
        let activated = requiresApplicationActivation
            ? performApplicationActivation(pid: item.pid)
            : true
        let succeeded = raised && activated
        Logger.activator.info(
            "activate result pid=\(item.pid, privacy: .public) windowID=\(item.id, privacy: .public) raised=\(raised, privacy: .public) appActivated=\(activated, privacy: .public) succeeded=\(succeeded, privacy: .public)"
        )
        return succeeded
    }

    func activateApplication(pid: pid_t) -> Bool {
        Logger.activator.info("activate app pid=\(pid, privacy: .public)")
        let activated = performApplicationActivation(pid: pid)
        Logger.activator.info("activate app result pid=\(pid, privacy: .public) appActivated=\(activated, privacy: .public)")
        return activated
    }

    func snap(_ item: WindowActionTarget, to edge: WindowSnapEdge) -> Bool {
        log(action: "snap \(edge.rawValue)", item: item)

        let appElement = appElement(for: item.pid)
        guard let match = matchingWindow(
            for: appElement,
            item: item,
            requireUniqueEvidence: true
        ) else {
            return false
        }
        let window = match.element

        var unminimized = true
        if item.isMinimized {
            unminimized = AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            ) == .success
        }

        let currentFrame = axFrame(on: window) ?? item.bounds
        let screenGeometries = Self.axScreenGeometries(from: NSScreen.screens)
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
        let requiresApplicationActivation = Self.shouldActivateApplication(afterTargeting: item)
        let activated = requiresApplicationActivation
            ? performApplicationActivation(pid: item.pid)
            : true
        let succeeded = unminimized
            && raiseResult == .success
            && mainResult == .success
            && focusResult == .success
            && activated
        logMatchDecision(
            action: "snap",
            item: item,
            match: match,
            raiseResult: raiseResult,
            mainResult: mainResult,
            focusResult: focusResult
        )
        Logger.activator.info(
            "snap result pid=\(item.pid, privacy: .public) windowID=\(item.id, privacy: .public) unminimized=\(unminimized, privacy: .public) appActivated=\(activated, privacy: .public) succeeded=\(succeeded, privacy: .public)"
        )
        return succeeded
    }

    func close(_ item: WindowActionTarget) -> Bool {
        log(action: "close", item: item)
        // Only close the window via AX — never terminate the app process.
        let closed = closeMatchingWindow(item)
        Logger.activator.info(
            "close result pid=\(item.pid, privacy: .public) windowID=\(item.id, privacy: .public) closed=\(closed, privacy: .public)"
        )
        return closed
    }

    func quit(_ item: WindowActionTarget) -> Bool {
        log(action: "quit", item: item)
        // Never quit SwitchBlade itself.
        guard item.pid != getpid(),
              let app = NSRunningApplication(processIdentifier: item.pid) else { return false }
        let requestAccepted = app.terminate()
        let confirmed = Self.confirmRequest(
            requestAccepted: requestAccepted,
            attempts: Self.activationConfirmationAttempts,
            isComplete: { app.isTerminated },
            wait: { usleep(Self.activationConfirmationIntervalMicroseconds) }
        )
        Logger.activator.info(
            "quit result pid=\(item.pid, privacy: .public) requestAccepted=\(requestAccepted, privacy: .public) confirmed=\(confirmed, privacy: .public)"
        )
        return confirmed
    }

    func hide(_ item: WindowActionTarget) -> Bool {
        log(action: "hide", item: item)
        guard item.pid != getpid(),
              let app = NSRunningApplication(processIdentifier: item.pid) else { return false }
        let requestAccepted = app.hide()
        let confirmed = Self.confirmRequest(
            requestAccepted: requestAccepted,
            attempts: Self.activationConfirmationAttempts,
            isComplete: { app.isHidden },
            wait: { usleep(Self.activationConfirmationIntervalMicroseconds) }
        )
        Logger.activator.info(
            "hide result pid=\(item.pid, privacy: .public) requestAccepted=\(requestAccepted, privacy: .public) confirmed=\(confirmed, privacy: .public)"
        )
        return confirmed
    }

    /// One log helper for all four actions so the format stays consistent and
    /// we never accidentally log a pid without a title.
    private func log(action: String, item: WindowActionTarget) {
        Logger.activator.info(
            "\(action, privacy: .public) pid=\(item.pid, privacy: .public) title=\(item.title, privacy: .private)"
        )
    }

    @discardableResult
    private func raiseMatchingWindow(_ item: WindowActionTarget) -> Bool {
        let appElement = appElement(for: item.pid)
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
    private func raiseWindow(_ item: WindowActionTarget) -> Bool {
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
        let requestAccepted = app.activate(options: [])
        // NSRunningApplication.activate only acknowledges the request. Real
        // telemetry has p95=84ms and p99=1.79s from request to frontmost
        // observation, so wait up to 2s before mutating MRU/hiding the panel.
        let activated = Self.confirmRequest(
            requestAccepted: requestAccepted,
            attempts: Self.activationConfirmationAttempts,
            isComplete: { app.isActive },
            wait: { usleep(Self.activationConfirmationIntervalMicroseconds) }
        )
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        PerformanceDiagnostics.record(
            "activation_app_activate",
            fields: [
                "activated": .bool(activated),
                "app_activate_ms": .double(elapsedMs),
                "pid": .int(Int(pid)),
                "request_accepted": .bool(requestAccepted)
            ]
        )
        Logger.activator.info(
            "App activate timing pid=\(pid, privacy: .public) requestAccepted=\(requestAccepted, privacy: .public) confirmed=\(activated, privacy: .public) elapsed=\(elapsedMs, format: .fixed(precision: 1), privacy: .public)ms"
        )
        return activated
    }

    static func confirmActivationRequest(
        requestAccepted: Bool,
        attempts: Int,
        isActive: () -> Bool,
        wait: () -> Void
    ) -> Bool {
        confirmRequest(
            requestAccepted: requestAccepted,
            attempts: attempts,
            isComplete: isActive,
            wait: wait
        )
    }

    static func confirmRequest(
        requestAccepted: Bool,
        attempts: Int,
        isComplete: () -> Bool,
        wait: () -> Void
    ) -> Bool {
        guard requestAccepted, attempts > 0 else { return false }
        for attempt in 0 ..< attempts {
            if isComplete() { return true }
            if attempt + 1 < attempts { wait() }
        }
        return false
    }

    @discardableResult
    private func performApplicationActivation(pid: pid_t) -> Bool {
        if let activateApplicationOverride {
            return activateApplicationOverride(pid)
        }
        return activateRunningApplication(pid: pid)
    }

    static func shouldActivateApplication(afterTargeting item: WindowActionTarget) -> Bool {
        // Same-app window switches already target the frontmost app. Re-running
        // app activation there can hand focus back to the app's previously-main
        // sibling window and undo the AX-targeted selection we just made.
        return !item.isFrontmostApp
    }

    static func shouldActivateApplication(afterTargeting item: WindowItem) -> Bool {
        shouldActivateApplication(afterTargeting: item.actionTarget)
    }

    private func closeMatchingWindow(_ item: WindowActionTarget) -> Bool {
        let appElement = appElement(for: item.pid)
        guard let match = matchingWindow(
            for: appElement,
            item: item,
            requireUniqueEvidence: true
        ) else {
            return false
        }

        let requestAccepted = pressCloseButton(on: match.element)
        return Self.confirmRequest(
            requestAccepted: requestAccepted,
            attempts: 20,
            isComplete: { Self.isInvalidAXElement(match.element) },
            wait: { usleep(Self.activationConfirmationIntervalMicroseconds) }
        )
    }

    private static func isInvalidAXElement(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &role
        ) == .invalidUIElement
    }

    private func pressCloseButton(on window: AXUIElement) -> Bool {
        applyAXMessagingTimeout(to: window)
        var closeButtonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonValue) == .success,
              let closeButtonValue,
              CFGetTypeID(closeButtonValue) == AXUIElementGetTypeID() else {
            return false
        }

        let closeButton = closeButtonValue as! AXUIElement
        applyAXMessagingTimeout(to: closeButton)

        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
    }

    private func appElement(for pid: pid_t) -> AXUIElement {
        let appElement = AXUIElementCreateApplication(pid)
        applyAXMessagingTimeout(to: appElement)
        return appElement
    }

    private func applyAXMessagingTimeout(to element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeoutSeconds)
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
        item: WindowActionTarget,
        preferNonMainOnTies: Bool = false,
        requireUniqueEvidence: Bool = false
    ) -> MatchedWindow? {
        let windowsStart = Date()
        guard let windows = windows(for: appElement) else {
            return nil
        }
        let windowsMs = Date().timeIntervalSince(windowsStart) * 1000

        let candidatesStart = Date()
        let candidateDeadline = ProcessInfo.processInfo.systemUptime
            + Self.maximumAXCandidateScanSeconds
        var candidates: [(element: AXUIElement, candidate: WindowMatchCandidate)] = []
        for window in windows.prefix(Self.maximumAXCandidateWindows) {
            guard ProcessInfo.processInfo.systemUptime < candidateDeadline else { break }
            applyAXMessagingTimeout(to: window)
            candidates.append((
                element: window,
                candidate: WindowMatchCandidate(
                    title: axString(kAXTitleAttribute, on: window),
                    frame: axFrame(on: window),
                    isMain: axBool(kAXMainAttribute, on: window),
                    isFocused: axBool(kAXFocusedAttribute, on: window)
                )
            ))
        }
        let candidatesMs = Date().timeIntervalSince(candidatesStart) * 1000
        let candidateScanWasBounded = candidates.count < windows.count

        let decisionStart = Date()
        if let decision = Self.bestMatchDecision(
            for: item,
            candidates: candidates.map(\.candidate),
            preferNonMainOnTies: preferNonMainOnTies,
            requireUniqueEvidence: requireUniqueEvidence
        ) {
            let decisionMs = Date().timeIntervalSince(decisionStart) * 1000
            PerformanceDiagnostics.record(
                "activation_ax_match",
                fields: [
                    "candidate_count": .int(candidates.count),
                    "candidate_scan_bounded": .bool(candidateScanWasBounded),
                    "candidate_total": .int(windows.count),
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
            "AX no matching window pid=\(item.pid, privacy: .public) windowID=\(item.id, privacy: .public) appWindows=\(windows.count, privacy: .public) scanned=\(candidates.count, privacy: .public) bounded=\(candidateScanWasBounded, privacy: .public) titleMatches=\(titleMatchCount, privacy: .public) frameMatches=\(frameMatchCount, privacy: .public) windowsMs=\(windowsMs, format: .fixed(precision: 1), privacy: .public) candidatesMs=\(candidatesMs, format: .fixed(precision: 1), privacy: .public) decisionMs=\(decisionMs, format: .fixed(precision: 1), privacy: .public)"
        )
        return nil
    }

    private func logMatchDecision(
        action: String,
        item: WindowActionTarget,
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
        for item: WindowActionTarget,
        candidates: [WindowMatchCandidate],
        preferNonMainOnTies: Bool = false,
        requireUniqueEvidence: Bool = false
    ) -> Int? {
        bestMatchDecision(
            for: item,
            candidates: candidates,
            preferNonMainOnTies: preferNonMainOnTies,
            requireUniqueEvidence: requireUniqueEvidence
        )?.index
    }

    static func bestMatchIndex(
        for item: WindowItem,
        candidates: [WindowMatchCandidate],
        preferNonMainOnTies: Bool = false,
        requireUniqueEvidence: Bool = false
    ) -> Int? {
        bestMatchIndex(
            for: item.actionTarget,
            candidates: candidates,
            preferNonMainOnTies: preferNonMainOnTies,
            requireUniqueEvidence: requireUniqueEvidence
        )
    }

    static func bestMatchDecision(
        for item: WindowActionTarget,
        candidates: [WindowMatchCandidate],
        preferNonMainOnTies: Bool = false,
        requireUniqueEvidence: Bool = false
    ) -> WindowMatchDecision? {
        guard !candidates.isEmpty else { return nil }

        let indexedCandidates = candidates.enumerated().map { (index: $0.offset, candidate: $0.element) }
        let exactTitleMatches = indexedCandidates.filter {
            titleMatches(item.title, candidateTitle: $0.candidate.title)
        }

        if requireUniqueEvidence {
            return uniqueEvidenceDecision(
                for: item,
                indexedCandidates: indexedCandidates,
                exactTitleMatches: exactTitleMatches
            )
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

    private static func uniqueEvidenceDecision(
        for item: WindowActionTarget,
        indexedCandidates: [(index: Int, candidate: WindowMatchCandidate)],
        exactTitleMatches: [(index: Int, candidate: WindowMatchCandidate)]
    ) -> WindowMatchDecision? {
        let frameMatches = indexedCandidates.filter { indexedCandidate in
            guard let frame = indexedCandidate.candidate.frame else { return false }
            return framesAreClose(frame, item.bounds)
        }

        if !item.title.isEmpty, exactTitleMatches.count == 1, let match = exactTitleMatches.first {
            return decision(
                match,
                reason: "unique-title",
                item: item,
                titleMatchCount: 1,
                frameMatchCount: frameMatches.count
            )
        }

        if !item.title.isEmpty, exactTitleMatches.count > 1 {
            let titleAndFrameMatches = exactTitleMatches.filter { indexedCandidate in
                guard let frame = indexedCandidate.candidate.frame else { return false }
                return framesAreClose(frame, item.bounds)
            }
            guard titleAndFrameMatches.count == 1, let match = titleAndFrameMatches.first else {
                return nil
            }
            return decision(
                match,
                reason: "unique-title-frame",
                item: item,
                titleMatchCount: exactTitleMatches.count,
                frameMatchCount: 1
            )
        }

        guard frameMatches.count == 1, let match = frameMatches.first else {
            return nil
        }
        return decision(
            match,
            reason: "unique-frame",
            item: item,
            titleMatchCount: item.title.isEmpty ? 0 : exactTitleMatches.count,
            frameMatchCount: 1
        )
    }

    private static func bestFrameCandidate(
        in candidates: [(index: Int, candidate: WindowMatchCandidate)],
        for item: WindowActionTarget,
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
        for item: WindowActionTarget,
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
        item: WindowActionTarget,
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
        let topY = visibleFrame.minY
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

    static func toAXScreenRect(_ rect: CGRect, rootScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: rootScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func axScreenGeometries(from screens: [NSScreen]) -> [ScreenGeometry] {
        let rootScreenFrame = screens.reduce(CGRect.null) { partial, screen in
            partial.isNull ? screen.frame : partial.union(screen.frame)
        }
        guard !rootScreenFrame.isNull else { return [] }
        return screens.map { screen in
            ScreenGeometry(
                frame: toAXScreenRect(screen.frame, rootScreenFrame: rootScreenFrame),
                visibleFrame: toAXScreenRect(screen.visibleFrame, rootScreenFrame: rootScreenFrame)
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
