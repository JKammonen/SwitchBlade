import CoreGraphics
import Foundation
@testable import SwitchBladeCore

/// Separates three facts the old result conflated: the selected row, the AX
/// element matched for it, and the window that finally has focus. Candidates
/// and focus samples are injected; the real decision, evidence, focus polling
/// and classification code runs. No native AX or window activation happens.
enum ActivationVerificationTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("ActivationVerification/uniqueMatchFocused_isSelectedTarget", uniqueMatchFocusedIsSelectedTarget),
        ("ActivationVerification/siblingFocused_isApplicationOnly", siblingFocusedIsApplicationOnly),
        ("ActivationVerification/blindSpot_matchedSiblingFocusIsNotIdentityProof", matchedSiblingFocusIsNotIdentityProof),
        ("ActivationVerification/blindSpot_titleTakeoverRemainsUndetected", titleTakeoverRemainsUndetected),
        ("ActivationVerification/raise_closestFrameGuessIsNotRaised", closestFrameGuessIsNotRaised),
        ("ActivationVerification/raise_untitledGuessIsNotRaised", untitledGuessIsNotRaised),
        ("ActivationVerification/raise_directEvidenceNeedsOwnTitleOrFrame", directEvidenceNeedsOwnTitleOrFrame),
        ("ActivationVerification/boundedCandidateScan_isWeakEvidence", boundedCandidateScanIsWeak),
        ("ActivationVerification/unreadableCandidateTitle_isWeakEvidence", unreadableCandidateTitleIsWeak),
        ("ActivationVerification/evidence_closestFrameAndFirstCandidateAreNeverUnique", closestFrameAndFirstCandidateAreNeverUnique),
        ("ActivationVerification/evidence_duplicateTitleNeedsUniqueFrame", duplicateTitleNeedsUniqueFrame),
        ("ActivationVerification/evidence_untitledNeedsUniqueReadableFrame", untitledNeedsUniqueReadableFrame),
        ("ActivationVerification/unknownFocus_isNeitherMismatchNorSuccess", unknownFocusIsNeitherMismatchNorSuccess),
        ("ActivationVerification/axTargetingFailure_skipsFocusObservation", axTargetingFailureSkipsFocusObservation),
        ("ActivationVerification/closedTarget_isNotSubstituted", closedTargetIsNotSubstituted),
        ("ActivationVerification/focusBudget_exhaustsWithoutRetryingActions", focusBudgetExhausts),
        ("ActivationVerification/focusBudget_acceptsLateMatchedFocus", focusBudgetAcceptsLateFocus),
        ("ActivationVerification/sameApp_verifiesWithoutActivationNotification", sameAppVerifies),
        ("ActivationVerification/userLeftDuringVerification_isNotSelectedTarget", userLeftDuringVerification),
        ("ActivationVerification/diagnostics_separateFactsWithoutTitles", diagnosticsSeparateFacts),
        ("ActivationVerification/store_applicationOnlyDoesNotRememberIntendedWindow", storeApplicationOnlyDoesNotRemember),
        ("ActivationVerification/store_sameAppApplicationOnlyKeepsRanks", storeSameAppApplicationOnlyKeepsRanks),
        ("ActivationVerification/store_verifiedSelectionIsRemembered", storeVerifiedSelectionIsRemembered),
        ("ActivationVerification/store_lateVerifiedResultCannotOverrideNewerFocus", storeLateVerifiedResultCannotOverrideNewerFocus),
        ("ActivationVerification/store_dispatchSeparatesQueueAndExecution", storeDispatchSeparatesQueueAndExecution),
        ("ActivationVerification/store_returnToSourceBeforeCompletionIsNotOverridden", storeReturnToSourceIsNotOverridden),
        ("ActivationVerification/store_oneCorrelationIDSpansRequestVerificationAndDispatch", storeOneCorrelationID)
    ]

    // MARK: - Fixtures

    private static let frameA = CGRect(x: 0, y: 0, width: 800, height: 600)
    private static let frameB = CGRect(x: 400, y: 300, width: 800, height: 600)

    private static func candidate(_ title: String?, _ frame: CGRect?) -> WindowActivator.WindowMatchCandidate {
        WindowActivator.WindowMatchCandidate(title: title, frame: frame, isMain: false, isFocused: false)
    }

    private static func sample(active: Bool = true, error: Int32 = 0, matched: Bool?) -> WindowActivator.MatchedElementFocusSample {
        WindowActivator.MatchedElementFocusSample(
            targetApplicationActive: active, focusedWindowError: error, focusedWindowIsMatchedElement: matched
        )
    }

    /// `focusedIndex` is the candidate that really holds focus; the activator
    /// only learns whether it equals the element it matched.
    private static func activator(
        candidates: [WindowActivator.WindowMatchCandidate],
        total: Int? = nil,
        focusedIndex: Int?,
        active: Bool = true,
        focusError: Int32 = 0,
        applicationActivated: Bool = true,
        alreadyActive: Bool = false,
        activationCalls: LockedValue<Int>? = nil,
        budget: TimeInterval = 0.03
    ) -> WindowActivator {
        WindowActivator(
            activateApplicationOverride: { _ in
                activationCalls?.withValue { $0 += 1 }
                return applicationActivated
            },
            isApplicationActiveOverride: { _ in alreadyActive },
            matchCandidatesOverride: { _ in (candidates, total ?? candidates.count) },
            focusSampleOverride: { _, matchedIndex in
                guard let focusedIndex else { return sample(active: active, error: focusError, matched: nil) }
                return sample(active: active, matched: matchedIndex == focusedIndex)
            },
            focusObservationBudgetSeconds: budget,
            focusObservationIntervalSeconds: 0.005
        )
    }

    private static func target(title: String = "A", bounds: CGRect = frameA,
                               pid: pid_t = 200, frontmost: Bool = false) -> WindowActionTarget {
        makeItem(id: 2, pid: pid, title: title, isFrontmostApp: frontmost, bounds: bounds).actionTarget
    }

    /// Captures the activator's own verification row for one action.
    @MainActor private static func verificationFields(
        _ body: () -> Void
    ) -> [String: PerformanceMetricValue]? {
        let captured = LockedValue<[String: PerformanceMetricValue]?>(nil)
        let previous = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            previous?(event, fields)
            if event == "activation_verification" { captured.value = fields }
        }
        defer { PerformanceDiagnostics.testObserver.value = previous }
        body()
        return captured.value
    }

    private static func string(_ fields: [String: PerformanceMetricValue]?, _ key: String) -> String? {
        guard case .string(let value)? = fields?[key] else { return nil }
        return value
    }

    private static func bool(_ fields: [String: PerformanceMetricValue]?, _ key: String) -> Bool? {
        guard case .bool(let value)? = fields?[key] else { return nil }
        return value
    }

    private static func int(_ fields: [String: PerformanceMetricValue]?, _ key: String) -> Int? {
        guard case .int(let value)? = fields?[key] else { return nil }
        return value
    }

    // MARK: - Activator classification

    @MainActor static func uniqueMatchFocusedIsSelectedTarget() throws {
        let activator = activator(candidates: [candidate("A", frameA), candidate("B", frameB)], focusedIndex: 0)
        var result: WindowActivationResult?
        let fields = verificationFields { result = activator.activateWithResult(target()) }
        try expectEqual(result, .selectedTarget)
        try expectEqual(string(fields, "match_evidence"), "unique")
        try expectEqual(string(fields, "match_evidence_basis"), "unique-title")
        try expectEqual(string(fields, "matched_element_focus"), "matched-element-focused")
    }

    @MainActor static func siblingFocusedIsApplicationOnly() throws {
        let activator = activator(candidates: [candidate("A", frameA), candidate("B", frameB)], focusedIndex: 1)
        var result: WindowActivationResult?
        let fields = verificationFields { result = activator.activateWithResult(target()) }
        try expectEqual(result, .applicationOnly, "app active with a sibling focused is not an exact selection")
        try expectEqual(string(fields, "legacy_result"), "selected-target", "old rule reported this as exact success")
        try expectEqual(string(fields, "result_reason"), "matched-element-other-window-focused")
    }

    /// Intended A, matched B, focused B. A was renamed and B sits exactly in
    /// A's old frame, so B is raised on direct frame evidence and really gets
    /// focus. That proves only that B got focus; the contradicted title keeps
    /// the result app-level. The old rule called this an exact selection.
    @MainActor static func matchedSiblingFocusIsNotIdentityProof() throws {
        let candidates = [candidate("X", CGRect(x: 2000, y: 0, width: 300, height: 200)),
                          candidate("B", frameA)]
        let activator = activator(candidates: candidates, focusedIndex: 1)
        var result: WindowActivationResult?
        let fields = verificationFields { result = activator.activateWithResult(target(title: "A")) }
        try expectEqual(string(fields, "match_reason"), "frame-close")
        try expectEqual(bool(fields, "raise_withheld"), false, "an exact frame is direct evidence for raising")
        try expectEqual(string(fields, "matched_element_focus"), "matched-element-focused",
                        "the matched element B really has focus")
        try expectEqual(result, .applicationOnly, "B's focus is not evidence that A was identified")
        try expectEqual(string(fields, "match_evidence_basis"), "title-not-found")
        try expectEqual(string(fields, "legacy_result"), "selected-target")
    }

    /// Live shape from 2026-10-21: the selected row was absent from AXWindows,
    /// which listed one window with another title elsewhere on screen. The old
    /// matcher raised that sibling as "closest-frame-no-title".
    @MainActor static func closestFrameGuessIsNotRaised() throws {
        for candidates in [[candidate("B", frameB)],
                           [candidate("X", CGRect(x: 2000, y: 0, width: 300, height: 200)), candidate("B", frameB)]] {
            let samples = LockedValue(0)
            let activator = WindowActivator(
                activateApplicationOverride: { _ in true },
                matchCandidatesOverride: { _ in (candidates, candidates.count) },
                focusSampleOverride: { _, _ in samples.withValue { $0 += 1 }; return sample(matched: true) }
            )
            var result: WindowActivationResult?
            let fields = verificationFields { result = activator.activateWithResult(target(title: "A")) }
            try expectEqual(string(fields, "match_reason"), "closest-frame-no-title")
            try expectEqual(bool(fields, "raise_withheld"), true, "a guess must not be raised")
            try expectEqual(result, .applicationOnly, "the app still activates")
            try expectEqual(string(fields, "result_reason"), "raise-withheld-title-not-found")
            try expectEqual(string(fields, "legacy_result"), "selected-target", "old rule raised and confirmed it")
            try expectEqual(samples.value, 0, "nothing was raised, so there is no matched element to observe")
        }
    }

    @MainActor static func untitledGuessIsNotRaised() throws {
        let activator = activator(candidates: [candidate("X", frameB), candidate("Y", CGRect(x: 2000, y: 0, width: 300, height: 200))],
                                  focusedIndex: 0)
        var result: WindowActivationResult?
        let fields = verificationFields { result = activator.activateWithResult(target(title: "")) }
        try expectEqual(bool(fields, "raise_withheld"), true)
        try expectEqual(result, .applicationOnly)
    }

    static func directEvidenceNeedsOwnTitleOrFrame() throws {
        let item = target(title: "A")
        try expect(WindowActivator.chosenCandidateHasDirectEvidence(for: item, candidate: candidate("A", frameB)))
        try expect(WindowActivator.chosenCandidateHasDirectEvidence(for: item, candidate: candidate("Renamed", frameA)))
        try expect(!WindowActivator.chosenCandidateHasDirectEvidence(for: item, candidate: candidate("B", frameB)))
        try expect(!WindowActivator.chosenCandidateHasDirectEvidence(for: item, candidate: candidate(nil, nil)))
        let untitled = target(title: "")
        try expect(!WindowActivator.chosenCandidateHasDirectEvidence(for: untitled, candidate: candidate("", frameB)),
                   "an empty title is not a title match")
    }

    /// Known limit: when sibling B takes over A's exact title, the match is
    /// unique by every attribute this data model has. Nothing here can tell
    /// B from A, so this stays an exact result. The test pins the limit; it
    /// does not claim B's focus identifies A.
    @MainActor static func titleTakeoverRemainsUndetected() throws {
        let candidates = [candidate("Renamed A", frameA), candidate("A", frameB)]
        let activator = activator(candidates: candidates, focusedIndex: 1)
        var result: WindowActivationResult?
        let fields = verificationFields { result = activator.activateWithResult(target(title: "A")) }
        try expectEqual(string(fields, "match_evidence_basis"), "unique-title")
        try expectEqual(result, .selectedTarget, "documented blind spot: title takeover is not detectable")
    }

    @MainActor static func boundedCandidateScanIsWeak() throws {
        let candidates = [candidate("A", frameA)] + (1..<32).map { candidate("Other \($0)", frameB) }
        let activator = activator(candidates: candidates, total: 40, focusedIndex: 0)
        var result: WindowActivationResult?
        let fields = verificationFields { result = activator.activateWithResult(target()) }
        try expectEqual(result, .applicationOnly, "a unique title in a prefix is not unique in the app")
        try expectEqual(string(fields, "match_evidence_basis"), "candidate-scan-bounded")
        try expectEqual(bool(fields, "candidate_scan_bounded"), true)
    }

    @MainActor static func unreadableCandidateTitleIsWeak() throws {
        let activator = activator(candidates: [candidate("A", frameA), candidate(nil, frameB)], focusedIndex: 0)
        var result: WindowActivationResult?
        let fields = verificationFields { result = activator.activateWithResult(target()) }
        try expectEqual(result, .applicationOnly, "an unreadable title could be another A")
        try expectEqual(string(fields, "match_evidence_basis"), "candidate-title-unavailable")
    }

    static func closestFrameAndFirstCandidateAreNeverUnique() throws {
        let item = target(title: "A")
        let candidates = [candidate("X", frameA), candidate("Y", frameB)]
        for chosen in [0, 1] {
            try expect(!WindowActivator.matchEvidence(for: item, candidates: candidates, chosenIndex: chosen,
                                                      candidateScanIsComplete: true).isUnique)
        }
        // Without frames the old matcher falls back to the first candidate.
        let frameless = [candidate("X", nil), candidate("Y", nil)]
        try expectEqual(WindowActivator.bestMatchDecision(for: item, candidates: frameless)?.reason, "fallback-no-title")
        try expect(!WindowActivator.matchEvidence(for: item, candidates: frameless, chosenIndex: 0,
                                                  candidateScanIsComplete: true).isUnique)
        // A singleton is not proof either: enumeration can omit the real target.
        try expect(!WindowActivator.matchEvidence(for: item, candidates: [candidate("X", frameB)], chosenIndex: 0,
                                                  candidateScanIsComplete: true).isUnique)
    }

    static func duplicateTitleNeedsUniqueFrame() throws {
        let item = target(title: "Untitled")
        let unique = [candidate("Untitled", frameA), candidate("Untitled", frameB)]
        try expectEqual(WindowActivator.matchEvidence(for: item, candidates: unique, chosenIndex: 0,
                                                      candidateScanIsComplete: true),
                        .unique("unique-title-frame"))
        try expectEqual(WindowActivator.matchEvidence(for: item, candidates: unique, chosenIndex: 1,
                                                      candidateScanIsComplete: true),
                        .weak("decision-differs-from-evidence"))
        let stacked = [candidate("Untitled", frameA), candidate("Untitled", frameA)]
        try expectEqual(WindowActivator.matchEvidence(for: item, candidates: stacked, chosenIndex: 0,
                                                      candidateScanIsComplete: true),
                        .weak("duplicate-title-ambiguous"))
        let missingFrame = [candidate("Untitled", frameA), candidate("Untitled", nil)]
        try expectEqual(WindowActivator.matchEvidence(for: item, candidates: missingFrame, chosenIndex: 0,
                                                      candidateScanIsComplete: true),
                        .weak("candidate-frame-unavailable"))
    }

    static func untitledNeedsUniqueReadableFrame() throws {
        let item = target(title: "")
        try expectEqual(WindowActivator.matchEvidence(for: item, candidates: [candidate("X", frameA), candidate("Y", frameB)],
                                                      chosenIndex: 0, candidateScanIsComplete: true),
                        .unique("unique-untitled-frame"))
        try expectEqual(WindowActivator.matchEvidence(for: item, candidates: [candidate("X", frameA), candidate("Y", nil)],
                                                      chosenIndex: 0, candidateScanIsComplete: true),
                        .weak("candidate-frame-unavailable"))
        try expectEqual(WindowActivator.matchEvidence(for: item, candidates: [candidate("X", frameB)],
                                                      chosenIndex: 0, candidateScanIsComplete: true),
                        .weak("frame-not-found"))
    }

    @MainActor static func unknownFocusIsNeitherMismatchNorSuccess() throws {
        let activator = activator(candidates: [candidate("A", frameA), candidate("B", frameB)],
                                  focusedIndex: nil, focusError: -25204)
        var result: WindowActivationResult?
        let fields = verificationFields { result = activator.activateWithResult(target()) }
        try expectEqual(result, .applicationOnly)
        try expectEqual(string(fields, "matched_element_focus"), "unknown", "unreadable focus is not other-window")
        try expectEqual(string(fields, "result_reason"), "matched-element-unknown")
        try expectEqual(int(fields, "focused_window_error"), -25204)
    }

    @MainActor static func axTargetingFailureSkipsFocusObservation() throws {
        let samples = LockedValue(0)
        let activator = WindowActivator(
            raiseWindowOverride: { _ in false },
            activateApplicationOverride: { _ in true },
            focusSampleOverride: { _, _ in samples.withValue { $0 += 1 }; return sample(matched: true) }
        )
        var result: WindowActivationResult?
        let fields = verificationFields { result = activator.activateWithResult(target()) }
        try expectEqual(result, .applicationOnly)
        try expectEqual(samples.value, 0, "there is no matched element to observe")
        try expectEqual(string(fields, "matched_element_focus"), "not-observed")
    }

    @MainActor static func closedTargetIsNotSubstituted() throws {
        // The selected window closed: AX lists no window at all for the app.
        let open = activator(candidates: [], focusedIndex: 0)
        try expectEqual(open.activateWithResult(target()), .applicationOnly)
        let failed = activator(candidates: [], focusedIndex: 0, applicationActivated: false)
        try expectEqual(failed.activateWithResult(target()), .failed)
        // A different survivor is not the closed window, even if it gets focus.
        let survivor = activator(candidates: [candidate("B", frameB)], focusedIndex: 0)
        try expectEqual(survivor.activateWithResult(target()), .applicationOnly)
    }

    static func focusBudgetExhausts() throws {
        var clock: TimeInterval = 0
        var samples = 0
        let observation = WindowActivator.observeMatchedElementFocus(
            budgetSeconds: 0.15, intervalSeconds: 0.015,
            now: { clock }, wait: { clock += $0 },
            sample: { samples += 1; return sample(matched: false) }
        )
        try expectEqual(observation.outcome, .otherWindowFocused)
        try expect(observation.budgetExhausted)
        try expectLessThanOrEqual(observation.elapsedMs, 150.0)
        try expectEqual(samples, observation.samples)
        try expectGreaterThan(samples, 1)
    }

    static func focusBudgetAcceptsLateFocus() throws {
        var clock: TimeInterval = 0
        var samples = 0
        let observation = WindowActivator.observeMatchedElementFocus(
            budgetSeconds: 0.15, intervalSeconds: 0.015,
            now: { clock }, wait: { clock += $0 },
            sample: { samples += 1; return samples < 3 ? sample(error: -25212, matched: nil) : sample(matched: true) }
        )
        try expectEqual(observation.outcome, .focused)
        try expect(!observation.budgetExhausted)
        try expectEqual(observation.samples, 3, "stop at the first matched sample; no stability floor")
    }

    @MainActor static func sameAppVerifies() throws {
        // Same app, already active: no app activation call and no activation
        // notification. Only the focus check can tell the two outcomes apart.
        for (focused, expected) in [(0, WindowActivationResult.selectedTarget), (1, .applicationOnly)] {
            let calls = LockedValue(0)
            let activator = activator(candidates: [candidate("A", frameA), candidate("B", frameB)],
                                      focusedIndex: focused, alreadyActive: true, activationCalls: calls)
            try expectEqual(activator.activateWithResult(target(pid: 100, frontmost: true)), expected)
            try expectEqual(calls.value, 0)
        }
    }

    @MainActor static func userLeftDuringVerification() throws {
        // Activation was confirmed, then another app took focus before the check.
        let activator = activator(candidates: [candidate("A", frameA), candidate("B", frameB)],
                                  focusedIndex: 0, active: false)
        var result: WindowActivationResult?
        let fields = verificationFields { result = activator.activateWithResult(target()) }
        try expectEqual(result, .applicationOnly)
        try expectEqual(string(fields, "matched_element_focus"), "target-application-inactive")
    }

    @MainActor static func diagnosticsSeparateFacts() throws {
        let secret = "Quarterly secret"
        let activator = activator(candidates: [candidate(secret, frameA), candidate("Other", frameB)], focusedIndex: 0)
        let fields = verificationFields { _ = activator.activateWithResult(target(title: secret)) } ?? [:]
        for key in ["window_id", "pid", "window_pid", "match_reason", "candidate_count", "candidate_total",
                    "candidate_scan_bounded", "match_evidence", "match_evidence_basis", "application_activated",
                    "matched_element_focus", "focus_verification_ms", "focus_samples", "result", "result_reason",
                    "legacy_result", "targeting_ms", "application_activation_ms", "activation_total_ms"] {
            try expect(fields[key] != nil, "missing \(key)")
        }
        try expectLessThanOrEqual(fields.count, PerformanceDiagnostics.maximumFieldCount)
        for value in fields.values {
            if case .string(let text) = value { try expect(!text.contains(secret), "window title leaked") }
        }
    }

    // MARK: - Store result handling

    private final class Gate: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
    }

    @MainActor private static func makeStore(
        activator: WindowActivator, tracker: MRUTracker, catalog: MockWindowCatalog
    ) -> SwitcherStore {
        SwitcherStore(
            catalog: catalog, activator: activator, permissionService: MockPermissionService(),
            userDefaults: makeIsolatedUserDefaults(), mruTracker: tracker,
            focusedRankUpgradeDelayNanoseconds: 5_000_000_000,
            workspaceNotificationCenter: NotificationCenter(),
            initialFrontmostAppPID: 100, switchBladePID: 999
        )
    }

    @MainActor private static func commitAndWait(
        _ store: SwitcherStore, selecting id: CGWindowID,
        whileRunning: (() -> Void)? = nil, started: LockedValue<Bool>? = nil, gate: Gate? = nil
    ) async throws -> [String: PerformanceMetricValue] {
        let dispatched = LockedValue<[String: PerformanceMetricValue]?>(nil)
        let previous = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            previous?(event, fields)
            if event == "selection_action_dispatch" || event == "selection_action_failed" { dispatched.value = fields }
        }
        defer { PerformanceDiagnostics.testObserver.value = previous }
        await openSwitcher(store)
        store.selectedID = id
        store.commitSelection()
        if let started, let gate {
            try await waitUntil { started.value }
            whileRunning?()
            gate.semaphore.signal()
        }
        try await waitUntil { dispatched.value != nil }
        return dispatched.value ?? [:]
    }

    private static func targetApp(focusedIndex: Int) -> WindowActivator {
        activator(candidates: [candidate("W2", frameA), candidate("W3", frameB)], focusedIndex: focusedIndex)
    }

    private static let crossAppWindows: [WindowItem] = [
        makeItem(id: 1, pid: 100, title: "W1", isFrontmostApp: true, bounds: frameB, bundleIdentifier: "fixture.source"),
        makeItem(id: 2, pid: 200, title: "W2", bounds: frameA, bundleIdentifier: "fixture.target"),
        makeItem(id: 3, pid: 200, title: "W3", bounds: frameB, bundleIdentifier: "fixture.target")
    ]

    @MainActor static func storeApplicationOnlyDoesNotRemember() async throws {
        let catalog = MockWindowCatalog()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let store = makeStore(activator: targetApp(focusedIndex: 1), tracker: tracker, catalog: catalog)
        defer { store.cancel() }
        for item in [crossAppWindows[2], crossAppWindows[1], crossAppWindows[0]] { tracker.trackFocusedWindowActivation(item) }
        catalog.visibleItems = crossAppWindows
        let fields = try await commitAndWait(store, selecting: 2)
        try expectEqual(string(fields, "result"), "application-only")
        try expect(tracker.recentWindowIDs.first != 2, "a focused sibling must not rank the intended window as exact")
    }

    @MainActor static func storeSameAppApplicationOnlyKeepsRanks() async throws {
        let catalog = MockWindowCatalog()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let windows = [makeItem(id: 1, pid: 100, title: "W1", isFrontmostApp: true, bounds: frameB),
                       makeItem(id: 2, pid: 100, title: "W2", isFrontmostApp: true, bounds: frameA)]
        let activator = activator(candidates: [candidate("W2", frameA), candidate("W1", frameB)],
                                  focusedIndex: 1, alreadyActive: true)
        let store = makeStore(activator: activator, tracker: tracker, catalog: catalog)
        defer { store.cancel() }
        for item in windows.reversed() { tracker.trackFocusedWindowActivation(item) }
        catalog.visibleItems = windows
        let ranksBefore = tracker.recentWindowIDs
        _ = try await commitAndWait(store, selecting: 2)
        try expectEqual(tracker.recentWindowIDs, ranksBefore, "same-app focus stayed on the sibling")
    }

    @MainActor static func storeVerifiedSelectionIsRemembered() async throws {
        let catalog = MockWindowCatalog()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let store = makeStore(activator: targetApp(focusedIndex: 0), tracker: tracker, catalog: catalog)
        defer { store.cancel() }
        for item in [crossAppWindows[2], crossAppWindows[1], crossAppWindows[0]] { tracker.trackFocusedWindowActivation(item) }
        catalog.visibleItems = crossAppWindows
        _ = try await commitAndWait(store, selecting: 2)
        try expectEqual(tracker.recentWindowIDs.first, 2)
    }

    @MainActor static func storeLateVerifiedResultCannotOverrideNewerFocus() async throws {
        let catalog = MockWindowCatalog()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let started = LockedValue(false)
        let gate = Gate()
        // Verification itself passed; the user moved on before the store ran
        // the completion on the main actor.
        let activator = WindowActivator(
            activateApplicationOverride: { _ in
                started.value = true
                return gate.semaphore.wait(timeout: .now() + 2) == .success
            },
            matchCandidatesOverride: { _ in ([candidate("W2", frameA), candidate("W3", frameB)], 2) },
            focusSampleOverride: { _, index in sample(matched: index == 0) }
        )
        let store = makeStore(activator: activator, tracker: tracker, catalog: catalog)
        defer { gate.semaphore.signal(); store.cancel() }
        let windows = crossAppWindows + [makeItem(id: 4, pid: 300, title: "W4", bundleIdentifier: "fixture.newer")]
        for item in windows.reversed() { tracker.trackFocusedWindowActivation(item) }
        catalog.visibleItems = windows
        var ranksBeforeCompletion: [CGWindowID] = []
        let fields = try await commitAndWait(store, selecting: 2, whileRunning: {
            store.handleAppActivation(pid: 200)
            store.handleAppActivation(pid: 300)
            ranksBeforeCompletion = tracker.recentWindowIDs
        }, started: started, gate: gate)
        try expectEqual(string(fields, "result"), "selected-target")
        try expectEqual(tracker.recentWindowIDs, ranksBeforeCompletion,
                        "an older verified result must not move ahead of newer external focus")
    }

    @MainActor static func storeDispatchSeparatesQueueAndExecution() async throws {
        let catalog = MockWindowCatalog()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let store = makeStore(activator: targetApp(focusedIndex: 0), tracker: tracker, catalog: catalog)
        defer { store.cancel() }
        catalog.visibleItems = crossAppWindows
        let fields = try await commitAndWait(store, selecting: 2)
        for key in ["queue_ms", "execution_ms", "action_ms"] {
            guard case .double(let value)? = fields[key] else { return try expect(false, "missing \(key)") }
            try expectGreaterThanOrEqual(value, 0.0)
        }
    }

    /// Codex review of 07d987f: the user returned to the source app while the
    /// action ran. PID equality saw "source is current" and promoted the old
    /// selection ahead of the source window.
    @MainActor static func storeReturnToSourceIsNotOverridden() async throws {
        let catalog = MockWindowCatalog()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let started = LockedValue(false)
        let gate = Gate()
        let activator = WindowActivator(
            activateApplicationOverride: { _ in
                started.value = true
                return gate.semaphore.wait(timeout: .now() + 2) == .success
            },
            matchCandidatesOverride: { _ in ([candidate("W2", frameA), candidate("W3", frameB)], 2) },
            focusSampleOverride: { _, index in sample(matched: index == 0) }
        )
        let store = makeStore(activator: activator, tracker: tracker, catalog: catalog)
        defer { gate.semaphore.signal(); store.cancel() }
        for item in crossAppWindows.reversed() { tracker.trackFocusedWindowActivation(item) }
        catalog.visibleItems = crossAppWindows
        // The previous fixture left this probe nil, bypassing the stale
        // outgoing-source update even though the selected rank was protected.
        catalog.focusedWindowItemsByPID[100] = crossAppWindows[0]
        try expectEqual(tracker.recentWindowIDs, [1, 2, 3])
        var ranksBeforeCompletion: [CGWindowID] = []
        let fields = try await commitAndWait(store, selecting: 2, whileRunning: {
            store.handleAppActivation(pid: 200)
            store.handleAppActivation(pid: 100)
            ranksBeforeCompletion = tracker.recentWindowIDs
        }, started: started, gate: gate)
        try expectEqual(string(fields, "result"), "selected-target")
        try expectEqual(tracker.recentWindowIDs, ranksBeforeCompletion,
                        "the newer return to the source app must keep its place")
        try expect(tracker.recentWindowIDs.first != 2)
    }

    @MainActor static func storeOneCorrelationID() async throws {
        let catalog = MockWindowCatalog()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let store = makeStore(activator: targetApp(focusedIndex: 0), tracker: tracker, catalog: catalog)
        defer { store.cancel() }
        catalog.visibleItems = crossAppWindows
        let rows = LockedValue<[String: [String: PerformanceMetricValue]]>([:])
        let previous = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            previous?(event, fields)
            if ["activation_request", "activation_verification"].contains(event) { rows.withValue { $0[event] = fields } }
        }
        defer { PerformanceDiagnostics.testObserver.value = previous }
        let dispatch = try await commitAndWait(store, selecting: 2)
        let id = string(dispatch, "correlation_id")
        try expectNotNil(id, "dispatch row needs the operation ID")
        try expectEqual(string(rows.value["activation_verification"], "correlation_id"), id,
                        "off-main verification must carry the same operation ID")
        try expectEqual(string(rows.value["activation_request"], "correlation_id"), id)
        try expectEqual(string(rows.value["activation_verification"], "diagnostic_context"), "selection-activate")
    }

    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(false, "operation did not reach the expected state")
    }
}
