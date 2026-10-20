import AppKit
import Foundation
@testable import SwitchBladeCore

/// Store-only regressions: no real panel, AX calls, or application activation.
enum CachedSwitchOrderingTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("CachedSwitch/freshSingleWindowCacheUsesCurrentMRU", freshCacheUsesCurrentMRU),
        ("CachedSwitch/staleSingleWindowCacheUsesCurrentMRUBeforeRefresh", staleCacheUsesCurrentMRU),
        ("CachedSwitch/rebasedSingleWindowCacheUsesCurrentMRU", rebasedCacheUsesCurrentMRU),
        ("CachedSwitch/cachedOpenPreservesAlphabeticalSort", cachedAlphabeticalSort),
        ("CachedSwitch/cachedOpenPreservesAppGroupedSort", cachedAppGroupedSort),
        ("CachedSwitch/resolvingReleaseReopensBeforeWarmup", resolvingReleaseReopens),
        ("CachedSwitch/preparedReleaseReopensBeforeWarmup", preparedReleaseReopens),
        ("CachedSwitch/lateActivationNotificationPreservesPreviousApp", lateNotificationPreservesHistory),
        ("CachedSwitch/missingActivationNotificationPreservesPreviousApp", missingNotificationPreservesHistory),
        ("CachedSwitch/processedTargetNotificationPreservesPreviousApp", processedNotificationPreservesHistory),
        ("CachedSwitch/snapReconcilesHistoryAndCachedFrontmost", snapReconcilesHistory),
        ("CachedSwitch/failedSnapPreservesHistoryAndMRU", failedSnapPreservesHistory),
        ("CachedSwitch/multiWindowSourceRetainsExactFocusedSiblingRank", multiWindowSourceRetainsFocusedRank),
        ("CachedSwitch/panelActivationDoesNotReplaceOriginalSourceWindow", panelActivationDoesNotReplaceOriginalSourceWindow),
        ("CachedSwitch/sourceFocusSurvivesFailedActionRetry", sourceFocusSurvivesFailedActionRetry),
        ("CachedSwitch/sourceFocusDoesNotSurviveSpaceChange", sourceFocusDoesNotSurviveSpaceChange),
        ("CachedSwitch/sourceFocusDoesNotSurviveCancellation", sourceFocusDoesNotSurviveCancellation),
        ("CachedSwitch/coalescedWarmupCannotSupplyOldSourceFocus", coalescedWarmupCannotSupplyOldSourceFocus),
        ("CachedSwitch/unconfirmedSourceDoesNotPromotePostPanelSibling", unconfirmedSourceDoesNotPromotePostPanelSibling),
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

    @MainActor private static func cachedAlphabeticalSort() async throws {
        try await cachedSortRemainsSelected(.alphabetical, expected: [1, 2, 4, 3])
    }

    @MainActor private static func cachedAppGroupedSort() async throws {
        try await cachedSortRemainsSelected(.appGrouped, expected: [1, 3, 4, 2])
    }

    @MainActor private static func cachedSortRemainsSelected(
        _ sort: SBSortOrder, expected: [UInt32]
    ) async throws {
        let settings = SwitchBladeSettings.shared
        let oldSort = settings.sortOrder
        settings.sortOrder = sort
        defer { settings.sortOrder = oldSort }
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let (store, catalog, _, _) = makeStore(mruTracker: tracker, initialFrontmostAppPID: 100)
        defer { store.cancel() }
        let windows = [
            makeItem(id: 1, pid: 100, appName: "Front", isFrontmostApp: true),
            makeItem(id: 2, pid: 200, appName: "Zulu", title: "Alpha"),
            makeItem(id: 3, pid: 300, appName: "Alpha", title: "Zulu"),
            makeItem(id: 4, pid: 400, appName: "Beta", title: "Beta")
        ]
        catalog.visibleItems = windows
        await store.warmPreviewCache(context: "sort-cache-seed")
        tracker.trackFocusedWindowActivation(windows[3])
        let snapshots = catalog.visibleSnapshotCount
        store.requestCycle(forward: true)
        try expectEqual(store.items.map(\.id), expected)
        try expectEqual(store.selectedID, expected[1])
        try expectEqual(catalog.visibleSnapshotCount, snapshots)
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

    @MainActor private static func processedNotificationPreservesHistory() async throws {
        try await visibleActionReconcilesHistory(snap: false)
    }

    @MainActor private static func snapReconcilesHistory() async throws {
        try await visibleActionReconcilesHistory(snap: true)
    }

    @MainActor private static func visibleActionReconcilesHistory(snap: Bool) async throws {
        let catalog = MockWindowCatalog()
        let activator = HeldActivation()
        let store = SwitcherStore(
            catalog: catalog, activator: activator, permissionService: MockPermissionService(),
            userDefaults: makeIsolatedUserDefaults(), workspaceNotificationCenter: NotificationCenter(),
            initialFrontmostAppPID: 100, switchBladePID: 999
        )
        defer { activator.release(); store.cancel() }
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true, bundleIdentifier: "fixture.a"),
            makeItem(id: 2, pid: 200, bundleIdentifier: "fixture.b")
        ]
        await openSwitcher(store)
        try expect(store.isVisible)
        let completion = selectionCompletionProbe()
        defer { completion.restore() }
        if snap {
            store.snap(store.items[1], to: .bottom)
        } else {
            store.selectedID = 2
            store.commitSelection()
        }
        try await waitUntil { activator.started.value }
        try expectEqual(store.isSwitching, snap, "activate hides early; snap completes while switching")
        store.handleAppActivation(pid: 200)
        activator.release()
        try await waitUntil { completion.completed.value }
        if snap {
            try expectEqual(activator.base.snapCalls, [.init(id: 2, edge: .bottom)])
            try expect(activator.base.activatedItems.isEmpty)
        } else {
            try expectEqual(activator.base.activatedItems.map(\.id), [2])
        }
        store.requestCycle(forward: true)
        try expectEqual(store.items.map(\.id), [2, 1])
        try expectEqual(store.items.map(\.isFrontmostApp), [true, false])
        try expectEqual(store.selectedID, 1)
        store.cancel()
        let settings = SwitchBladeSettings.shared
        let wasEnabled = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = wasEnabled }
        store.switchToPreviousApplication()
        try await waitUntil { !activator.base.activatedApplicationPIDs.isEmpty }
        try expectEqual(activator.base.activatedApplicationPIDs, [100])
    }

    private enum SourceFocusScenario { case normal, failedRetry, spaceChange, cancelAndReopen, coalescedWarmup, noEvidence }

    @MainActor private static func panelActivationDoesNotReplaceOriginalSourceWindow() async throws {
        try await assertSourceFocus(.normal)
    }

    @MainActor private static func sourceFocusSurvivesFailedActionRetry() async throws {
        try await assertSourceFocus(.failedRetry)
    }

    @MainActor private static func sourceFocusDoesNotSurviveSpaceChange() async throws {
        try await assertSourceFocus(.spaceChange)
    }

    @MainActor private static func sourceFocusDoesNotSurviveCancellation() async throws {
        try await assertSourceFocus(.cancelAndReopen)
    }

    @MainActor private static func coalescedWarmupCannotSupplyOldSourceFocus() async throws {
        try await assertSourceFocus(.coalescedWarmup)
    }

    @MainActor private static func unconfirmedSourceDoesNotPromotePostPanelSibling() async throws {
        try await assertSourceFocus(.noEvidence)
    }

    @MainActor private static func assertSourceFocus(_ scenario: SourceFocusScenario) async throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let (store, catalog, activator, _) = makeStore(mruTracker: tracker, initialFrontmostAppPID: 100)
        defer { store.cancel() }
        let booking = makeItem(id: 1, pid: 100, title: "Booking", isFrontmostApp: true)
        let main = makeItem(id: 16, pid: 100, title: "Calendar", isFrontmostApp: true)
        let others = (2...15).map { makeItem(id: UInt32($0), pid: pid_t($0 * 100)) }
        let windows = [booking] + others + [main]
        for item in windows.reversed() { tracker.trackFocusedWindowActivation(item) }
        catalog.visibleItems = windows
        catalog.snapshotFocusedWindow = scenario == .noEvidence ? nil : booking
        catalog.focusedWindowItemsByPID[100] = booking
        store.onShow = {
            // Panel activation can change the source app's AX-focused sibling.
            catalog.focusedWindowItemsByPID[100] = main
        }
        let completion = selectionCompletionProbe()
        defer { completion.restore() }
        let usedSources = LockedValue<[Int]>([])
        let oldObserver = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            oldObserver?(event, fields)
            if event == "focus_rank_decision",
               case .string("pre-panel-source-focus")? = fields["context"],
               case .string("used-for-selection")? = fields["outcome"],
               case .int(let id)? = fields["window_id"] {
                usedSources.withValue { $0.append(id) }
            }
        }
        defer { PerformanceDiagnostics.testObserver.value = oldObserver }
        var warmup: Task<Void, Never>?
        if scenario == .coalescedWarmup {
            catalog.visibleSnapshotDelayNanoseconds = 50_000_000
            catalog.snapshotFocusedWindow = main
            warmup = Task { await store.warmPreviewCache(context: "old-focus-before-hotkey") }
            try await waitUntil { catalog.visibleSnapshotCount == 1 }
            catalog.snapshotFocusedWindow = booking
        }
        store.requestCycle(forward: true)
        try await waitUntil { store.isVisible }
        if scenario == .coalescedWarmup {
            await warmup?.value
            try expectEqual(catalog.visibleSnapshotCount, 2,
                            "multi-window warmup predating the open needs fresh focus before panel show")
        }
        if scenario == .spaceChange || scenario == .cancelAndReopen {
            catalog.snapshotFocusedWindow = nil
            catalog.visibleItems = [main] + others + [booking]
            if scenario == .spaceChange {
                await store.handleActiveSpaceChange()
            } else {
                store.cancel()
                store.requestCycle(forward: true)
            }
            try await waitUntil { store.isVisible }
        }
        store.selectedID = 2
        if scenario == .failedRetry { activator.activationSucceeds = false }
        store.commitSelection()
        try await waitUntil { completion.completed.value }
        if scenario == .failedRetry {
            try expect(store.isVisible, "failure must retain the recovery panel")
            completion.completed.value = false
            activator.activationSucceeds = true
            store.commitSelection()
            try await waitUntil { completion.completed.value }
        }
        let order = tracker.orderedForDisplay(from: windows.map { $0.withFrontmostState($0.pid == 200) })
        let sourceWasInvalidated = scenario == .spaceChange || scenario == .cancelAndReopen
        try expectEqual(Array(order.prefix(2).map(\.id)), [2, scenario == .cancelAndReopen ? 16 : 1],
                        "source history must use this open's valid pre-panel focus, including recovery retries")
        if sourceWasInvalidated || scenario == .noEvidence {
            try expect(usedSources.value.isEmpty, "invalidated/unconfirmed source cannot be used as pre-panel evidence")
        } else {
            try expect(!usedSources.value.isEmpty && usedSources.value.allSatisfy { $0 == 1 })
        }
        if !sourceWasInvalidated {
            try expectEqual(order.last?.id, main.id, "unvisited sibling must retain its own rank")
            try expectEqual(catalog.focusedWindowItemCallCount, 0, "confirmed source needs no post-panel AX rescan")
        }
    }

    @MainActor private static func multiWindowSourceRetainsFocusedRank() async throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let catalog = MockWindowCatalog()
        let activator = HeldActivation()
        let store = makeHeldStore(catalog: catalog, activator: activator, tracker: tracker)
        defer { activator.release(); store.cancel() }
        let windows = (1...16).map { index in
            let pid: pid_t = index == 16 ? 100 : pid_t(index * 100)
            return makeItem(id: UInt32(index), pid: pid, title: "Fixture \(index)",
                            isFrontmostApp: pid == 100, bundleIdentifier: "fixture.\(pid)")
        }
        for item in windows.reversed() { tracker.trackFocusedWindowActivation(item) }
        catalog.visibleItems = windows
        catalog.focusedWindowItemsByPID[100] = windows[0]
        store.requestCycle(forward: true)
        store.commitSelection()
        try await waitUntil { activator.started.value }
        // A sibling reported after the transition must never replace the exact
        // pre-activation focus captured by the detached action.
        catalog.focusedWindowItemsByPID[100] = windows[15]
        store.handleAppActivation(pid: 200)
        activator.release()
        try await waitUntil { !store.isSwitching }
        let snapshots = catalog.visibleSnapshotCount
        store.requestCycle(forward: true)
        let expected = [UInt32(2), 1] + Array(UInt32(3)...UInt32(16))
        try expectEqual(store.items.map(\.id), expected)
        try expectEqual(tracker.recentWindowIDs, expected)
        try expectEqual(store.selectedID, 1)
        try expectEqual(catalog.visibleSnapshotCount, snapshots)
        try expectEqual(catalog.focusedWindowItemCallCount, 1)
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
            workspaceNotificationCenter: NotificationCenter(),
            initialFrontmostAppPID: 100, switchBladePID: 999
        )
        defer { activator.release(); store.cancel() }
        let completion = selectionCompletionProbe()
        defer { completion.restore() }
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
        try await waitUntil { completion.completed.value }

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

    @MainActor private static func failedSnapPreservesHistory() async throws {
        try await selectionPreservesHistory(succeeds: false, snap: true)
    }

    @MainActor private static func selectionPreservesHistory(succeeds: Bool, snap: Bool = false) async throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let catalog = MockWindowCatalog()
        let activator = HeldActivation()
        activator.base.activationSucceeds = succeeds
        activator.base.snapSucceeds = succeeds
        let store = makeHeldStore(catalog: catalog, activator: activator, tracker: tracker)
        defer { activator.release(); store.cancel() }
        let completion = selectionCompletionProbe()
        defer { completion.restore() }
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
        if snap { store.snap(target, to: .bottom) } else { store.commitSelection() }
        try await waitUntil { activator.started.value }
        activator.release()
        try await waitUntil { completion.completed.value }
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
                      workspaceNotificationCenter: NotificationCenter(),
                      initialFrontmostAppPID: 100, switchBladePID: 999)
    }

    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(false, "mock operation did not reach the expected state")
    }

    private static func selectionCompletionProbe() -> (completed: LockedValue<Bool>, restore: () -> Void) {
        let completed = LockedValue(false)
        let previousObserver = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            previousObserver?(event, fields)
            if event == "selection_action_dispatch" || event == "selection_action_failed" {
                completed.value = true
            }
        }
        return (completed, { PerformanceDiagnostics.testObserver.value = previousObserver })
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
        func snap(_ item: WindowActionTarget, to edge: WindowSnapEdge) -> Bool {
            started.value = true
            guard gate.wait(timeout: .now() + 2) == .success else { return false }
            return base.snap(item, to: edge)
        }
        func close(_ item: WindowActionTarget) -> Bool { base.close(item) }
        func quit(_ item: WindowActionTarget) -> Bool { base.quit(item) }
        func hide(_ item: WindowActionTarget) -> Bool { base.hide(item) }
    }
}
