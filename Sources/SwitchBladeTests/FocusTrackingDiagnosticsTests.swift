import AppKit
@testable import SwitchBladeCore

/// Exercise real state gates without native focus changes, including the
/// external activation that previously left the observer on the wrong app.
enum FocusTrackingDiagnosticsTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("FocusDiagnostics/externalActivationAcrossCancelKeepsTracking", activationAcrossCancel),
        ("FocusDiagnostics/visibleActivationDefersOnlyExactFocus", visibleActivation),
        ("FocusDiagnostics/newerActivationSupersedesDeferredFocus", newerActivation),
        ("FocusDiagnostics/rapidReopenRetainsDeferredFocusUntilAccepted", rapidReopen),
        ("FocusDiagnostics/returnToSourceRejectsOlderSnapshotSibling", returnToSourceSnapshot),
        ("FocusDiagnostics/committedSelectionSupersedesDeferredFocusWithoutSiblingScan", committedSelection),
        ("FocusDiagnostics/failedSelectionRetainsDeferredFocusUntilCancel", failedSelection),
        ("FocusDiagnostics/resolutionDiscardedDuringOpenKeepsCorrelation", resolutionDiscardedDuringOpen),
        ("FocusDiagnostics/acceptedFocusSharesCorrelationWithoutPrivateText", acceptedFocus),
        ("FocusDiagnostics/samplingIsBoundedAndNeverChangesRanks", samplingIsBounded)
    ]

    private final class Recording: @unchecked Sendable {
        let entries = LockedValue<[(String, [String: PerformanceMetricValue])]>([])
        private let previous = PerformanceDiagnostics.testObserver.value
        init() {
            let entries = entries
            PerformanceDiagnostics.testObserver.value = { event, fields in
                entries.withValue { $0.append((event, fields)) }
            }
        }
        func stop() { PerformanceDiagnostics.testObserver.value = previous }
        func fields(_ event: String) -> [[String: PerformanceMetricValue]] {
            entries.value.filter { $0.0 == event }.map(\.1)
        }
        func has(_ event: String, outcome: String) -> Bool {
            fields(event).contains { string($0, "outcome") == outcome }
        }
    }

    @MainActor private final class Observer: WindowFocusObserving {
        var onFocus: ((WindowFocusCapture) -> Void)?
        var observedPIDs: [pid_t?] = []
        func observe(pid: pid_t?) { observedPIDs.append(pid) }
        func emit(_ item: WindowItem, id: String, gate: LockedValue<Bool>? = nil) {
            onFocus?(WindowFocusCapture(pid: item.pid, diagnosticID: id, resolve: {
                let deadline = Date().addingTimeInterval(2)
                while gate?.value == false, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                return item
            }))
        }
    }

    @MainActor private final class Fixture {
        let observer = Observer()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let catalog = MockWindowCatalog()
        let windows: [WindowItem]
        let store: SwitcherStore
        init(focusedRankUpgradeDelay: UInt64 = 5_000_000_000,
             activator: WindowActivating = MockWindowActivator()) {
            // Same scale as the reported 19-row open. Codex starts with an old
            // concrete rank so a missing visit is distinguishable from fallback.
            windows = (1...19).map { (index: Int) -> WindowItem in
                // Above macOS's real PID range: otherwise 1100/1200 can
                // collide with Dock/NotificationCenter bundle lookups.
                let pid = pid_t(1_000_000 + index * 100)
                return makeItem(id: UInt32(index), pid: pid,
                         appName: "PRIVATE_APP_SENTINEL", title: "PRIVATE_TITLE_SENTINEL",
                         isFrontmostApp: index == 1, bundleIdentifier: "fixture.\(index)")
            }
            for item in windows.reversed() { tracker.trackFocusedWindowActivation(item) }
            catalog.visibleItems = windows
            store = SwitcherStore(
                catalog: catalog, activator: activator, permissionService: MockPermissionService(),
                windowFocusObserver: observer, userDefaults: makeIsolatedUserDefaults(), mruTracker: tracker,
                focusedRankUpgradeDelayNanoseconds: focusedRankUpgradeDelay,
                workspaceNotificationCenter: NotificationCenter(), initialFrontmostAppPID: windows[0].pid, switchBladePID: 999,
                bundleIdentifierForPID: { "fixture.\(($0 - 1_000_000) / 100)" }
            )
        }
    }

    @MainActor private static func activationAcrossCancel() async throws {
        let recording = Recording()
        defer { recording.stop() }
        let f = Fixture(focusedRankUpgradeDelay: 0)
        defer { f.store.cancel() }
        let codex = f.windows[10]
        f.catalog.focusedWindowItemsByPID[codex.pid] = codex
        f.catalog.visibleSnapshotDelayNanoseconds = 50_000_000
        f.store.requestCycle(forward: true)
        f.store.handleAppActivation(pid: codex.pid)
        try expectEqual(f.catalog.focusedWindowItemCallCount, 0,
                        "defer AX work until the panel no longer owns focus")
        f.store.cancel()
        try await waitUntil { f.tracker.recentWindowIDs.first == codex.id }
        f.observer.emit(codex, id: "missed-codex-visit")
        f.store.sampleFocusTracking(frontmostPID: codex.pid, uptime: 100)

        try expect(recording.has("app_activation_received", outcome: "deferred-focus-switching"))
        let processed = recording.fields("app_activation_processed").last ?? [:]
        try expectEqual(int(processed, "current_pid"), Int(codex.pid))
        try expectEqual(int(processed, "observer_requested_pid"), Int(codex.pid))
        try expect(!recording.has("foreground_focus_decision", outcome: "discarded-pid-mismatch"))
        try expect(recording.has("focus_tracking_sample", outcome: "aligned"))
        let sample = recording.fields("focus_tracking_sample").last ?? [:]
        try expectEqual(int(sample, "frontmost_pid"), Int(codex.pid))
        try expectEqual(string(sample, "phase"), "idle")
        try expectEqual(f.tracker.recentWindowIDs.first, codex.id)
        try await waitUntil { recording.has("foreground_focus_decision", outcome: "accepted") }
        let next = f.windows[1]
        f.catalog.focusedWindowItemsByPID[next.pid] = next
        f.catalog.visibleItems = f.windows.map { $0.withFrontmostState($0.pid == next.pid) }
        f.store.handleAppActivation(pid: next.pid)
        try await waitUntil { f.tracker.recentWindowIDs.first == next.id }
        try expectEqual(Array(f.tracker.orderedForDisplay(from: f.catalog.visibleItems).prefix(2).map(\.id)),
                        [next.id, codex.id], "the actual Codex visit must survive the next departure")
    }

    @MainActor private static func visibleActivation() async throws {
        let recording = Recording()
        defer { recording.stop() }
        let f = Fixture(focusedRankUpgradeDelay: 0)
        defer { f.store.cancel() }
        await openSwitcher(f.store)
        let codex = f.windows[10]
        f.catalog.focusedWindowItemsByPID[codex.pid] = codex
        let displayed = f.store.items.map(\.id)
        f.store.handleAppActivation(pid: codex.pid)
        try expectEqual(f.store.items.map(\.id), displayed, "history changes must not move the visible selection/list")
        try expect(recording.has("app_activation_received", outcome: "deferred-focus-visible"))
        let received = recording.fields("app_activation_received").last ?? [:]
        try expectEqual(string(received, "phase"), "visible")
        try expectEqual(int(received, "activation_sequence"), 1)
        try expectEqual(f.catalog.focusedWindowItemCallCount, 0)
        f.store.cancel()
        try await waitUntil { f.tracker.recentWindowIDs.first == 11 }
        f.store.sampleFocusTracking(frontmostPID: codex.pid, uptime: 100)
        try expect(recording.has("focus_tracking_sample", outcome: "aligned"))
    }

    @MainActor private static func newerActivation() async throws {
        let recording = Recording()
        defer { recording.stop() }
        let f = Fixture(focusedRankUpgradeDelay: 0)
        defer { f.store.cancel() }
        await openSwitcher(f.store)
        let first = f.windows[10], latest = f.windows[11]
        f.catalog.focusedWindowItemsByPID[first.pid] = first
        f.catalog.focusedWindowItemsByPID[latest.pid] = latest
        f.store.handleAppActivation(pid: first.pid)
        f.store.handleAppActivation(pid: latest.pid)
        f.store.handleAppActivation(pid: 999) // panel activation is not user history
        f.store.cancel()
        try await waitUntil { f.tracker.recentWindowIDs.first == 12 }
        try expectEqual(f.observer.observedPIDs.last!, latest.pid)
        try expectEqual(f.catalog.focusedWindowItemCallCount, 1,
                        "only the latest deferred app may receive the late AX upgrade")
        f.catalog.visibleItems = f.windows.map { $0.withFrontmostState($0.pid == latest.pid) }
        try expectEqual(Array(f.tracker.orderedForDisplay(from: f.catalog.visibleItems).prefix(2).map(\.id)), [12, 11])
    }

    private final class HeldActivator: WindowActivating, @unchecked Sendable {
        let started = LockedValue(false)
        let gate = DispatchSemaphore(value: 0)
        let succeeds: Bool
        init(succeeds: Bool) { self.succeeds = succeeds }
        func activate(_ item: WindowActionTarget) -> Bool {
            started.value = true
            return gate.wait(timeout: .now() + 2) == .success && succeeds
        }
        func activateApplication(pid: pid_t) -> Bool { false }
        func reopenApplication(pid: pid_t) -> Bool { false }
        func snap(_ item: WindowActionTarget, to edge: WindowSnapEdge) -> Bool { false }
        func close(_ item: WindowActionTarget) -> Bool { false }
        func quit(_ item: WindowActionTarget) -> Bool { false }
        func hide(_ item: WindowActionTarget) -> Bool { false }
    }

    @MainActor private static func rapidReopen() async throws {
        let recording = Recording()
        defer { recording.stop() }
        let f = Fixture(focusedRankUpgradeDelay: 60_000_000)
        defer { f.store.cancel() }
        let codex = f.windows[10]
        f.catalog.focusedWindowItemsByPID[codex.pid] = codex
        f.store.requestCycle(forward: true)
        f.store.handleAppActivation(pid: codex.pid)
        f.store.cancel()
        // Reopen before the deferred probe's delay elapses, and let its state
        // guard reject this attempt. Closing again must resume the same visit.
        f.store.requestCycle(forward: true)
        try await waitUntil { recording.has("focus_rank_decision", outcome: "discarded-state-before-probe") }
        f.store.cancel()
        try await waitUntil { f.tracker.recentWindowIDs.first == codex.id }
        try expectEqual(f.catalog.focusedWindowItemCallCount, 1)
    }

    @MainActor private static func returnToSourceSnapshot() async throws {
        let recording = Recording()
        defer { recording.stop() }
        let f = Fixture(focusedRankUpgradeDelay: 0)
        defer { f.store.cancel() }
        let source = f.windows[0], other = f.windows[10]
        let sibling = makeItem(id: 99, pid: source.pid, isFrontmostApp: true,
                               bundleIdentifier: source.bundleIdentifier)
        f.catalog.visibleItems.append(sibling)
        await f.store.warmPreviewCache(context: "multi-window-source-seed")
        f.catalog.snapshotFocusedWindow = source
        f.catalog.visibleSnapshotDelayNanoseconds = 50_000_000
        let before = f.catalog.visibleSnapshotCount
        f.store.requestCycle(forward: true)
        try await waitUntil { f.catalog.visibleSnapshotCount > before }
        f.store.handleAppActivation(pid: other.pid)
        f.store.handleAppActivation(pid: source.pid)
        f.catalog.focusedWindowItemsByPID[source.pid] = sibling
        try await waitUntil { f.store.isVisible }
        try expect(!recording.fields("focus_rank_decision").contains {
            string($0, "context") == "pre-panel-source-focus" && string($0, "outcome") == "captured"
        }, "A -> B -> A must not make the older A window current again")
        try expect(!recording.fields("mru_remember").contains {
            string($0, "context") == "switcher-open-focus"
        }, "the old snapshot must not promote a stale source sibling")
        f.store.cancel()
        try await waitUntil { f.tracker.recentWindowIDs.first == sibling.id }
    }

    @MainActor private static func committedSelection() async throws {
        try await selectionAfterDeferredActivation(succeeds: true)
    }

    @MainActor private static func failedSelection() async throws {
        try await selectionAfterDeferredActivation(succeeds: false)
    }

    @MainActor private static func selectionAfterDeferredActivation(succeeds: Bool) async throws {
        let recording = Recording()
        defer { recording.stop() }
        let activator = HeldActivator(succeeds: succeeds)
        let f = Fixture(focusedRankUpgradeDelay: 0, activator: activator)
        defer { activator.gate.signal(); f.store.cancel() }
        await openSwitcher(f.store)
        let external = f.windows[10], target = f.windows[1]
        f.catalog.focusedWindowItemsByPID[external.pid] = external
        f.store.handleAppActivation(pid: external.pid)
        f.store.selectedID = target.id
        f.store.commitSelection()
        try await waitUntil { activator.started.value }
        try expect(!f.store.isSwitching, "activate hides before the detached action returns")
        try expect(recording.fields("deferred_focus_upgrade").isEmpty,
                        "hiding a committed action must not probe while it owns the lane")
        if succeeds { f.store.handleAppActivation(pid: target.pid) }
        activator.gate.signal()
        try await waitUntil { !recording.fields(succeeds ? "selection_action_dispatch" : "selection_action_failed").isEmpty }
        if succeeds {
            try expectEqual(f.tracker.recentWindowIDs.first, target.id)
            try expect(recording.fields("deferred_focus_upgrade").isEmpty,
                       "verified self-selection must replace deferred focus without a sibling scan")
            try expect(recording.fields("focus_rank_scheduled").isEmpty)
        } else {
            try expect(f.store.isVisible, "failed action retains its recovery panel")
            try expect(recording.fields("deferred_focus_upgrade").isEmpty)
            f.store.cancel()
            try await waitUntil { f.tracker.recentWindowIDs.first == external.id }
            try expect(recording.has("deferred_focus_upgrade", outcome: "resumed"))
        }
    }

    @MainActor private static func resolutionDiscardedDuringOpen() async throws {
        let recording = Recording()
        defer { recording.stop() }
        let f = Fixture()
        let gate = LockedValue(false)
        defer { gate.value = true; f.store.cancel() }
        let item = f.windows[0]
        f.observer.emit(item, id: "focus-during-open", gate: gate)
        await openSwitcher(f.store)
        gate.value = true
        try await waitUntil { recording.has("foreground_focus_decision", outcome: "discarded-switching") }
        let decisions = recording.fields("foreground_focus_decision")
            .filter { string($0, "correlation_id") == "focus-during-open" }
        try expectEqual(decisions.count, 2)
        try expectEqual(string(decisions[0], "stage"), "received")
        try expectEqual(string(decisions[1], "stage"), "resolved")
        try expectEqual(int(decisions[1], "window_id"), 1)
        let resolution = recording.fields("foreground_focus_resolution").last ?? [:]
        try expectEqual(string(resolution, "correlation_id"), "focus-during-open")
    }

    @MainActor private static func acceptedFocus() async throws {
        let previousLogging = PerformanceLoggingState.mode
        PerformanceLoggingState.mode = .debug
        defer { PerformanceLoggingState.mode = previousLogging }
        let recording = Recording()
        defer { recording.stop() }
        let f = Fixture()
        defer { f.store.cancel() }
        f.observer.emit(f.windows[0], id: "accepted-focus")
        try await waitUntil { recording.has("foreground_focus_decision", outcome: "accepted") }
        for event in ["foreground_focus_resolution", "foreground_window_focus", "mru_remember"] {
            let fields = recording.fields(event).last ?? [:]
            try expectEqual(string(fields, "correlation_id"), "accepted-focus", event)
        }
        for (event, fields) in recording.entries.value {
            let data = try PerformanceDiagnostics.metricLine(event: event, fields: fields, timestamp: "test")
            try expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE_"))
        }
    }

    @MainActor private static func samplingIsBounded() throws {
        let recording = Recording()
        defer { recording.stop() }
        let f = Fixture()
        defer { f.store.cancel() }
        let before = f.tracker.recentWindowIDs
        f.store.sampleFocusTracking(frontmostPID: f.windows[0].pid, uptime: 100)
        f.store.sampleFocusTracking(frontmostPID: f.windows[0].pid, uptime: 101)
        f.store.sampleFocusTracking(frontmostPID: f.windows[0].pid, uptime: 129)
        f.store.sampleFocusTracking(frontmostPID: f.windows[0].pid, uptime: 130)
        f.store.sampleFocusTracking(frontmostPID: f.windows[10].pid, uptime: 131)
        f.store.sampleFocusTracking(frontmostPID: 999, uptime: 132)
        f.store.sampleFocusTracking(frontmostPID: nil, uptime: 133)
        let fields = recording.fields("focus_tracking_sample")
        try expectEqual(fields.count, 5)
        try expectEqual(string(fields[1], "sample_reason"), "heartbeat")
        try expectEqual(string(fields[2], "outcome"), "mismatch")
        try expectEqual(string(fields[3], "outcome"), "own-app")
        try expectEqual(string(fields[4], "outcome"), "frontmost-unavailable")
        try expectEqual(f.tracker.recentWindowIDs, before)
        try expectEqual(f.catalog.visibleSnapshotCount, 0)
        try expectEqual(f.catalog.focusedWindowItemCallCount, 0)
    }

    private static func string(_ fields: [String: PerformanceMetricValue], _ key: String) -> String? {
        guard case .string(let value)? = fields[key] else { return nil }; return value
    }
    private static func int(_ fields: [String: PerformanceMetricValue], _ key: String) -> Int? {
        guard case .int(let value)? = fields[key] else { return nil }; return value
    }
    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(false, "diagnostic path did not complete")
    }
}
