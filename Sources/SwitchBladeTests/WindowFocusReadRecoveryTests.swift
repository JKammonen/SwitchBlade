import ApplicationServices
@testable import SwitchBladeCore

enum WindowFocusReadRecoveryTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("FocusRead/transientFailuresRecoverExactWindow", recovers),
        ("FocusRead/repeatedFailureIsBounded", bounded),
        ("FocusRead/permanentAndMalformedReadsDoNotRetry", permanent),
        ("FocusRead/departureBeforeRetryStopsReading", departure),
        ("FocusRead/departureDuringReadDiscardsCapture", departureDuringRead),
        ("FocusRead/newNotificationSupersedesPendingRetry", superseded),
        ("FocusRead/selfActionCancelsSamePIDRetry", cancellation),
        ("FocusRead/cancellationDuringAXReadDiscardsCapture", reentrantCancellation),
        ("FocusRead/eligibilityCheckedAgainBeforeRetry", eligibility),
        ("FocusRead/registrationRetryPreservesMembershipInvalidation", membership),
        ("FocusRead/recoveredWindowEntersRealScaleHistory", history),
        ("FocusRead/storeOpenCancelsRetryAndSuppressesActionReads", storeCancellation),
        ("FocusRead/storeSameAppActionCannotRankLateSibling", storeSameAppAction),
        ("FocusRead/diagnosticsDescribeExhaustionWithoutPrivateText", diagnosticExhaustion)
    ]

    @MainActor private final class Harness: WindowFocusObserving {
        var onFocus: ((WindowFocusCapture) -> Void)?
        var shouldCaptureFocus: (() -> Bool)?
        var frontmost: pid_t? = 1_000_100
        var allowed = true
        var calls: [WindowFocusReadRecovery.Request] = []
        var delivered: [WindowFocusCapture] = []
        var failures = 0
        var terminalError: AXError?
        var malformed: String?
        var duringRead: (() -> Void)?
        var focused = makeItem(id: 19, pid: 1_000_100, title: "PRIVATE_TITLE_SENTINEL", bundleIdentifier: "fixture.1")
        lazy var driver = WindowFocusReadRecovery(
            retryDelays: [10_000_000, 10_000_000, 10_000_000],
            frontmostPID: { [weak self] in self?.frontmost },
            isAllowed: { [weak self] in
                guard let self else { return false }
                return self.allowed && (self.shouldCaptureFocus?() ?? true)
            }, read: { [weak self] request in
                guard let self else { return .failure(.invalidUIElement, "discarded-no-registration") }
                self.calls.append(request)
                self.duringRead?()
                if let error = self.terminalError { return .failure(error, "ax-error") }
                if let malformed = self.malformed { return .failure(.success, malformed) }
                if self.failures > 0 { self.failures -= 1; return .failure(.cannotComplete, "ax-error") }
                // Retain the identity from this read, exactly as the native AX
                // adapter retains its element. Later focus may be a sibling.
                let item = self.focused
                return .captured(WindowFocusCapture(pid: request.pid,
                    invalidatesMembership: request.invalidatesMembership, diagnosticID: request.diagnosticID,
                    resolve: { item }))
            }, deliver: { [weak self] capture in
                self?.delivered.append(capture)
                self?.onFocus?(capture)
            }
        )
        func observe(pid: pid_t?) { cancelPendingFocusReads() }
        func cancelPendingFocusReads() { driver.cancel(reason: "observer-or-action-change") }
        func emit(trigger: String = "focused-window-changed", invalidates: Bool = true) {
            driver.capture(pid: focused.pid, trigger: trigger, invalidatesMembership: invalidates)
        }
    }

    @MainActor private static func settled() async throws { try await Task.sleep(nanoseconds: 65_000_000) }

    @MainActor private static func recovers() async throws {
        let h = Harness()
        h.failures = 2
        h.emit()
        try await settled()
        try expectEqual(h.calls.count, 3)
        try expectEqual(h.delivered.count, 1)
        try expectEqual(h.delivered.first?.resolve()?.id, 19)
        try expectEqual(Set(h.calls.map(\.diagnosticID)).count, 1, "all attempts share their originating correlation")
        try expectEqual(h.delivered.first?.diagnosticID, h.calls.first?.diagnosticID)
    }

    @MainActor private static func bounded() async throws {
        let h = Harness()
        h.failures = 100
        h.emit()
        try await settled()
        try expectEqual(h.calls.map(\.attempt), [0, 1, 2, 3])
        try expectEqual(h.delivered.count, 0, "failure is not focus evidence")
    }

    @MainActor private static func permanent() async throws {
        for error: AXError in [.apiDisabled, .attributeUnsupported, .invalidUIElement, .noValue] {
            let h = Harness()
            h.terminalError = error
            h.emit()
            try await settled()
            try expectEqual(h.calls.count, 1)
            try expectEqual(h.delivered.count, 0)
        }
        for outcome in ["missing-value", "unexpected-value-type"] {
            let h = Harness()
            h.malformed = outcome
            h.emit()
            try await settled()
            try expectEqual(h.calls.count, 1)
            try expectEqual(h.delivered.count, 0)
        }
    }

    @MainActor private static func departure() async throws {
        let h = Harness()
        h.failures = 1
        h.emit()
        h.frontmost = 1_000_200
        try await settled()
        try expectEqual(h.calls.count, 1)
        try expectEqual(h.delivered.count, 0)
    }

    @MainActor private static func departureDuringRead() async throws {
        let h = Harness()
        h.duringRead = { [weak h] in h?.frontmost = 1_000_200 }
        h.emit()
        try await settled()
        try expectEqual(h.calls.count, 1)
        try expectEqual(h.delivered.count, 0, "a completed AX read is invalid after foreground changes")
    }

    @MainActor private static func superseded() async throws {
        let h = Harness()
        h.failures = 1
        h.emit()
        let oldID = h.calls[0].diagnosticID
        h.focused = makeItem(id: 20, pid: 1_000_100)
        h.emit()
        try await settled()
        try expectEqual(h.calls.count, 2)
        try expectEqual(h.delivered.count, 1)
        try expectEqual(h.delivered[0].resolve()?.id, 20)
        try expect(h.delivered[0].diagnosticID != oldID)
    }

    @MainActor private static func cancellation() async throws {
        let h = Harness()
        h.failures = 1
        h.emit()
        h.cancelPendingFocusReads()
        h.focused = makeItem(id: 1, pid: 1_000_100)
        try await settled()
        try expectEqual(h.calls.count, 1)
        try expectEqual(h.delivered.count, 0)
    }

    @MainActor private static func eligibility() async throws {
        let h = Harness()
        h.failures = 1
        h.emit()
        h.allowed = false
        try await settled()
        h.allowed = true
        try await settled()
        try expectEqual(h.calls.count, 1, "a blocked retry never resumes after the action ends")
        try expectEqual(h.delivered.count, 0)
    }

    @MainActor private static func reentrantCancellation() async throws {
        let h = Harness()
        h.duringRead = { [weak h] in h?.cancelPendingFocusReads() }
        h.emit()
        try expectEqual(h.delivered.count, 0, "cancellation inside AX IPC must invalidate its completed result")
    }

    @MainActor private static func membership() async throws {
        let h = Harness()
        h.failures = 1
        h.emit(trigger: "window-created")
        h.emit(trigger: "registration", invalidates: false)
        try expectEqual(h.delivered.first?.invalidatesMembership, true)
        try await settled()
        try expectEqual(h.delivered.count, 1)
    }

    @MainActor private final class History {
        let observer = Harness()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let catalog = MockWindowCatalog()
        let activator = MockWindowActivator()
        let store: SwitcherStore
        init() {
            let main = makeItem(id: 1, pid: 1_000_100, bundleIdentifier: "fixture.1")
            let others = (2...18).map { makeItem(id: UInt32($0), pid: pid_t(1_000_000 + $0 * 100), bundleIdentifier: "fixture.\($0)") }
            for item in ([main] + others).reversed() { tracker.trackFocusedWindowActivation(item) }
            catalog.visibleItems = [main] + others + [observer.focused]
            catalog.focusedWindowItemsByPID[main.pid] = main
            store = SwitcherStore(catalog: catalog, activator: activator,
                permissionService: MockPermissionService(), windowFocusObserver: observer,
                userDefaults: makeIsolatedUserDefaults(), mruTracker: tracker,
                focusedRankUpgradeDelayNanoseconds: 0, workspaceNotificationCenter: NotificationCenter(),
                initialFrontmostAppPID: main.pid, switchBladePID: 999,
                bundleIdentifierForPID: { "fixture.\(($0 - 1_000_000) / 100)" })
        }
    }

    @MainActor private static func history() async throws {
        let f = History()
        defer { f.store.cancel() }
        f.observer.failures = 2
        f.observer.emit()
        try await settled()
        await runPendingMainTasks()
        try expectEqual(f.tracker.recentWindowIDs.first, 19, "recovered message must outrank its older main window among 19 rows")
        // Native outgoing AX would now report main. Departure must use the
        // recovered captured element, never substitute that changed sibling.
        f.observer.focused = f.catalog.visibleItems[0]
        let next = f.catalog.visibleItems[1]
        f.catalog.focusedWindowItemsByPID[next.pid] = next
        f.catalog.visibleItems = f.catalog.visibleItems.map { $0.withFrontmostState($0.pid == next.pid) }
        f.observer.frontmost = next.pid
        f.store.handleAppActivation(pid: next.pid)
        await runPendingMainTasks()
        let order = f.tracker.orderedForDisplay(from: f.catalog.visibleItems)
        try expectEqual(Array(order.prefix(3).map(\.id)), [2, 19, 1])
    }

    @MainActor private static func storeCancellation() async throws {
        let f = History()
        defer { f.store.cancel() }
        f.observer.failures = 1
        f.observer.emit()
        f.store.requestCycle(forward: true)
        // Notifications arriving while resolving must not create a retry that
        // survives cancellation or an exact same-app selection.
        f.observer.emit()
        f.store.cancel()
        try await settled()
        try expectEqual(f.observer.calls.count, 1)
        try expectEqual(f.observer.delivered.count, 0)
        f.observer.emit()
        await runPendingMainTasks()
        try expectEqual(f.tracker.recentWindowIDs.first, 19, "fresh idle user focus still works after cancellation")
    }

    @MainActor private static func storeSameAppAction() async throws {
        let f = History()
        defer { f.store.cancel() }
        // Populate the real action's live item set before exercising its lane
        // from idle. An empty UI model cannot remember any selected identity.
        await openSwitcher(f.store)
        f.store.cancel()
        let target = f.observer.focused
        try expect(f.store.items.contains { $0.id == target.id })
        f.activator.actionDelayNanoseconds = 80_000_000
        f.observer.failures = 1
        f.observer.emit()
        f.store.snap(target, to: .left)
        f.observer.focused = f.catalog.visibleItems[0]
        f.observer.emit()
        try await Task.sleep(nanoseconds: 130_000_000)
        await runPendingMainTasks()
        try expectEqual(f.activator.snapCalls.count, 1)
        try expectEqual(f.observer.calls.count, 1, "same-PID action cancels old retry and suppresses new notifications during its lane")
        try expectEqual(f.observer.delivered.count, 0)
        try expectEqual(f.tracker.recentWindowIDs.first, target.id)
    }

    @MainActor private static func diagnosticExhaustion() async throws {
        let entries = LockedValue<[[String: PerformanceMetricValue]]>([])
        let previous = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            if event == "focus_observer_capture" { entries.withValue { $0.append(fields) } }
        }
        defer { PerformanceDiagnostics.testObserver.value = previous }
        let h = Harness()
        h.failures = 100
        h.emit()
        try await settled()
        let rows = entries.value
        let outcomes = rows.compactMap { row -> String? in
            guard case .string(let value)? = row["outcome"] else { return nil }
            return value
        }
        try expectEqual(outcomes.filter { $0 == "retry-scheduled" }.count, 3)
        try expectEqual(outcomes.filter { $0 == "retry-exhausted" }.count, 1)
        let ids = rows.compactMap { row -> String? in
            guard case .string(let value)? = row["correlation_id"] else { return nil }
            return value
        }
        try expectEqual(Set(ids).count, 1)
        try expectEqual(ids.first, h.calls.first?.diagnosticID)
        let strings = rows.flatMap { $0.values }.compactMap { value -> String? in
            guard case .string(let text) = value else { return nil }
            return text
        }
        try expect(!strings.contains { $0.contains("PRIVATE_TITLE_SENTINEL") })
    }
}
