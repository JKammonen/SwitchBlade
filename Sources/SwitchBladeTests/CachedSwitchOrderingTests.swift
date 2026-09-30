import AppKit
import Foundation
@testable import SwitchBladeCore

/// Store-only regressions: no real panel, AX calls, or application activation.
enum CachedSwitchOrderingTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("CachedSwitch/freshSingleWindowCacheUsesCurrentMRU", freshCacheUsesCurrentMRU),
        ("CachedSwitch/staleSingleWindowCacheUsesCurrentMRUBeforeRefresh", staleCacheUsesCurrentMRU),
        ("CachedSwitch/rebasedSingleWindowCacheUsesCurrentMRU", rebasedCacheUsesCurrentMRU),
        ("CachedSwitch/resolvingReleaseReopensBeforeWarmup", resolvingReleaseReopens),
        ("CachedSwitch/preparedReleaseReopensBeforeWarmup", preparedReleaseReopens),
        ("CachedSwitch/lateActivationNotificationPreservesPreviousApp", lateNotificationPreservesHistory),
        ("CachedSwitch/missingActivationNotificationPreservesPreviousApp", missingNotificationPreservesHistory),
        ("CachedSwitch/newerExternalActivationSurvivesOlderCompletion", newerActivationSurvivesCompletion),
        ("CachedSwitch/sameAppSelectionPreservesPreviousApp", sameAppSelectionPreservesHistory),
        ("CachedSwitch/failedActivationPreservesHistoryAndMRU", failedActivationPreservesHistory)
    ]

    @MainActor private static func freshCacheUsesCurrentMRU() async throws {
        try await cachedOrderUsesCurrentMRU(maxAge: 30, rebase: false)
    }

    @MainActor private static func staleCacheUsesCurrentMRU() async throws {
        try await cachedOrderUsesCurrentMRU(maxAge: 0, rebase: false)
    }

    @MainActor private static func rebasedCacheUsesCurrentMRU() async throws {
        try await cachedOrderUsesCurrentMRU(maxAge: 30, rebase: true)
    }

    @MainActor private static func cachedOrderUsesCurrentMRU(maxAge: TimeInterval, rebase: Bool) async throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let (store, catalog, _, _) = makeStore(
            mruTracker: tracker, cachedOpenItemsMaxAge: maxAge, initialFrontmostAppPID: 100
        )
        defer { store.cancel() }
        // The real diagnostic sample contained 10–19 rows. Keep the promotion
        // at the far end of a 16-row cache, with one window in the current app.
        let windows = (1...16).map { index in
            makeItem(id: UInt32(index), pid: pid_t(index * 100), title: "Fixture \(index)",
                     isFrontmostApp: index == 1, bundleIdentifier: "fixture.\(index)")
        }
        for item in windows.reversed() { tracker.trackFocusedWindowActivation(item) }
        catalog.visibleItems = windows
        await store.warmPreviewCache(context: "cached-order-seed")
        if rebase { store.handleAppActivation(pid: 200) }
        tracker.trackFocusedWindowActivation(windows[15])
        let frontmostID: UInt32 = rebase ? 2 : 1
        let expected = [frontmostID, 16] + windows.map(\.id).filter { $0 != frontmostID && $0 != 16 }
        let snapshotCount = catalog.visibleSnapshotCount
        catalog.visibleSnapshotDelayNanoseconds = 150_000_000
        catalog.minimizedSnapshotDelayNanoseconds = 150_000_000
        var firstPaint: [UInt32] = []
        store.onShow = { firstPaint = store.items.map(\.id) }

        store.requestCycle(forward: true)

        try expectEqual(firstPaint, expected, "cached first paint must use current MRU without waiting for either scan")
        try expectEqual(store.selectedID, 16)
        try expectEqual(catalog.visibleSnapshotCount, snapshotCount, "ordering must stay on the cached fast path")
    }

    @MainActor private static func resolvingReleaseReopens() async throws {
        try await quickReleaseReopens(prepared: false, notification: .duringAction)
    }

    @MainActor private static func preparedReleaseReopens() async throws {
        try await quickReleaseReopens(prepared: true, notification: .duringAction)
    }

    @MainActor private static func lateNotificationPreservesHistory() async throws {
        try await quickReleaseReopens(prepared: true, notification: .afterAction)
    }

    @MainActor private static func missingNotificationPreservesHistory() async throws {
        try await quickReleaseReopens(prepared: true, notification: .none)
    }

    private enum NotificationTiming { case duringAction, afterAction, none }

    @MainActor private static func quickReleaseReopens(prepared: Bool, notification: NotificationTiming) async throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let catalog = MockWindowCatalog()
        let activator = HeldActivation()
        let store = makeHeldStore(catalog: catalog, activator: activator, tracker: tracker)
        defer { activator.release(); store.cancel() }
        let a = makeItem(id: 1, pid: 100, isFrontmostApp: true, bundleIdentifier: "fixture.a")
        let b = makeItem(id: 2, pid: 200, bundleIdentifier: "fixture.b")
        catalog.visibleItems = [a, b]
        catalog.focusedWindowItemsByPID[100] = a
        catalog.focusedWindowItemsByPID[200] = b
        if prepared { await store.warmPreviewCache(context: "quick-release-seed") }
        var showCount = 0
        store.onShow = { showCount += 1 }
        store.requestCycle(forward: true)
        store.commitSelection()
        try await waitUntil { activator.started.value }
        try expect(store.isSwitching && !store.isVisible)
        if notification == .duringAction { store.handleAppActivation(pid: 200) }
        activator.release()
        try await waitUntil { !store.isSwitching }
        try expectEqual(showCount, 0, "quick release must never show a panel")
        if notification == .afterAction { store.handleAppActivation(pid: 200) }

        let events = LockedValue<[[String: PerformanceMetricValue]]>([])
        let previousObserver = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            if event == "open_cache_decision" { events.withValue { $0.append(fields) } }
        }
        defer { PerformanceDiagnostics.testObserver.value = previousObserver }
        let snapshotCount = catalog.visibleSnapshotCount
        store.requestCycle(forward: true)
        try expectEqual(store.items.map(\.id), [2, 1], "successful target must own cached slot zero before warmup")
        try expectEqual(store.selectedID, 1, "the next Cmd+Tab must return B → A")
        guard case .int(let trackedPID)? = events.value.last?["current_pid"] else {
            try expect(false, "missing current-app diagnostic")
            return
        }
        try expectEqual(trackedPID, 200)
        try expectEqual(catalog.visibleSnapshotCount, snapshotCount)
        store.cancel()

        // Exercise previous-app history through its public gesture, including
        // the no-notification case and an already-delivered notification.
        let settings = SwitchBladeSettings.shared
        let wasEnabled = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = wasEnabled }
        store.switchToPreviousApplication()
        try await waitUntil { !activator.base.activatedApplicationPIDs.isEmpty }
        try expectEqual(activator.base.activatedApplicationPIDs, [100])
    }

    @MainActor private static func sameAppSelectionPreservesHistory() async throws {
        try await selectionPreservesHistory(succeeds: true)
    }

    @MainActor private static func newerActivationSurvivesCompletion() async throws {
        let catalog = MockWindowCatalog()
        let activator = HeldActivation()
        let store = SwitcherStore(
            catalog: catalog, activator: activator, permissionService: MockPermissionService(),
            userDefaults: makeIsolatedUserDefaults(), focusedRankUpgradeDelayNanoseconds: 5_000_000_000,
            initialFrontmostAppPID: 100, switchBladePID: 999
        )
        defer { activator.release(); store.cancel() }
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true, bundleIdentifier: "fixture.a"),
            makeItem(id: 2, pid: 200, bundleIdentifier: "fixture.b"),
            makeItem(id: 3, pid: 300, bundleIdentifier: "fixture.c")
        ]
        await openSwitcher(store)
        store.selectedID = 2
        store.commitSelection()
        try await waitUntil { activator.started.value }
        store.handleAppActivation(pid: 200)
        store.handleAppActivation(pid: 300)
        activator.release()
        try await waitUntil { !activator.base.activatedItems.isEmpty }
        await runPendingMainTasks()

        store.requestCycle(forward: true)
        try expectEqual(store.items.first?.id, 3, "an older action must not replace newer observed focus")
        store.cancel()
        let settings = SwitchBladeSettings.shared
        let wasEnabled = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = wasEnabled }
        store.switchToPreviousApplication()
        try await waitUntil { !activator.base.activatedApplicationPIDs.isEmpty }
        try expectEqual(activator.base.activatedApplicationPIDs, [200])
    }

    @MainActor private static func failedActivationPreservesHistory() async throws {
        try await selectionPreservesHistory(succeeds: false)
    }

    @MainActor private static func selectionPreservesHistory(succeeds: Bool) async throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let catalog = MockWindowCatalog()
        let activator = HeldActivation()
        activator.base.activationSucceeds = succeeds
        let store = makeHeldStore(catalog: catalog, activator: activator, tracker: tracker)
        defer { activator.release(); store.cancel() }
        let a = makeItem(id: 1, pid: 100, isFrontmostApp: true, bundleIdentifier: "fixture.a")
        let target = makeItem(id: 2, pid: succeeds ? 100 : 200, isFrontmostApp: succeeds,
                              bundleIdentifier: succeeds ? "fixture.a" : "fixture.b")
        let c = makeItem(id: 3, pid: 300, bundleIdentifier: "fixture.c")
        catalog.visibleItems = [a, target, c]
        store.handleAppActivation(pid: 300)
        store.handleAppActivation(pid: 100)
        store.requestCycle(forward: true)
        try await waitUntil { store.items.count == 3 }
        store.selectedID = target.id
        let ranksBefore = tracker.recentWindowIDs
        store.commitSelection()
        try await waitUntil { activator.started.value }
        activator.release()
        try await waitUntil { !activator.base.activatedItems.isEmpty }
        await runPendingMainTasks()
        if !succeeds { try expectEqual(tracker.recentWindowIDs, ranksBefore) }
        store.cancel()
        // Membership can shrink independently; with one current-app window,
        // the previous-app gesture directly exposes the preserved history.
        catalog.visibleItems = [succeeds ? target : a, c]
        await store.warmPreviewCache(context: "history-check")
        let settings = SwitchBladeSettings.shared
        let wasEnabled = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = wasEnabled }
        store.switchToPreviousApplication()
        try await waitUntil { !activator.base.activatedApplicationPIDs.isEmpty }
        try expectEqual(activator.base.activatedApplicationPIDs, [300])
    }

    @MainActor private static func makeHeldStore(
        catalog: MockWindowCatalog, activator: HeldActivation, tracker: MRUTracker
    ) -> SwitcherStore {
        SwitcherStore(catalog: catalog, activator: activator, permissionService: MockPermissionService(),
                      userDefaults: makeIsolatedUserDefaults(), mruTracker: tracker,
                      initialPanelShowDelayNanoseconds: 5_000_000_000,
                      focusedRankUpgradeDelayNanoseconds: 5_000_000_000,
                      initialFrontmostAppPID: 100, switchBladePID: 999)
    }

    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(false, "mock operation did not reach the expected state")
    }

    /// Holds the detached action until the test delivers its notification.
    /// The bounded wait and deferred release prevent a failed test stranding it.
    private final class HeldActivation: WindowActivating, @unchecked Sendable {
        let base = MockWindowActivator()
        let started = LockedValue(false)
        private let gate = DispatchSemaphore(value: 0)
        func release() { gate.signal() }
        func activate(_ item: WindowActionTarget) -> Bool {
            started.value = true
            guard gate.wait(timeout: .now() + 2) == .success else { return false }
            return base.activate(item)
        }
        func activateApplication(pid: pid_t) -> Bool { base.activateApplication(pid: pid) }
        func reopenApplication(pid: pid_t) -> Bool { base.reopenApplication(pid: pid) }
        func snap(_ item: WindowActionTarget, to edge: WindowSnapEdge) -> Bool { base.snap(item, to: edge) }
        func close(_ item: WindowActionTarget) -> Bool { base.close(item) }
        func quit(_ item: WindowActionTarget) -> Bool { base.quit(item) }
        func hide(_ item: WindowActionTarget) -> Bool { base.hide(item) }
    }
}
