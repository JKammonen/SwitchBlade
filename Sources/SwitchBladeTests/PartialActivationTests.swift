import AppKit
import Foundation
@testable import SwitchBladeCore

/// Real activation/store code with injected platform calls; no user windows move.
enum PartialActivationTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("PartialActivation/visibleReleaseDismissesAfterAppOnlyActivation", visibleRelease),
        ("PartialActivation/preparedReleaseStaysHiddenAfterAppOnlyActivation", preparedRelease),
        ("PartialActivation/resolvingReleaseStaysHiddenAfterAppOnlyActivation", resolvingRelease),
        ("PartialActivation/frontmostAppRequiresActiveConfirmation", frontmostAppRequiresConfirmation),
        ("PartialActivation/failedAppActivationKeepsRecoveryPanel", failedAppActivation),
        ("PartialActivation/newerExternalActivationSurvivesAppOnlyCompletion", newerExternalActivation)
    ]

    private enum Phase { case visible, prepared, resolving }

    @MainActor private static func visibleRelease() async throws { try await appOnlyRelease(.visible) }
    @MainActor private static func preparedRelease() async throws { try await appOnlyRelease(.prepared) }
    @MainActor private static func resolvingRelease() async throws { try await appOnlyRelease(.resolving) }

    @MainActor private static func appOnlyRelease(_ phase: Phase) async throws {
        let catalog = MockWindowCatalog()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let activatedPIDs = LockedValue<[pid_t]>([])
        let activator = WindowActivator(
            raiseWindowOverride: { _ in false },
            activateApplicationOverride: { pid in
                activatedPIDs.withValue { $0.append(pid) }
                return true
            }
        )
        let store = SwitcherStore(
            catalog: catalog, activator: activator, permissionService: MockPermissionService(),
            userDefaults: makeIsolatedUserDefaults(), mruTracker: tracker,
            initialPanelShowDelayNanoseconds: phase == .visible ? 0 : 5_000_000_000,
            focusedRankUpgradeDelayNanoseconds: 5_000_000_000,
            workspaceNotificationCenter: NotificationCenter(),
            initialFrontmostAppPID: 100, switchBladePID: 999
        )
        defer { store.cancel() }
        // Live failure had 8–9 rows. Two target-app windows ensure an app-only
        // result cannot silently promote the selected sibling as exact focus.
        let windows: [WindowItem] = (1...8).map { index in
            let appIndex = index == 3 ? 2 : index
            return makeItem(id: UInt32(index), pid: pid_t(appIndex * 100),
                            isFrontmostApp: index == 1, bundleIdentifier: "fixture.\(appIndex)")
        }
        for index in [1, 7, 6, 5, 4, 3, 2, 0] { tracker.trackFocusedWindowActivation(windows[index]) }
        let ranksBefore = tracker.recentWindowIDs
        catalog.visibleItems = windows
        var showCount = 0
        store.onShow = { showCount += 1 }
        let completed = LockedValue(false)
        let previousObserver = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            previousObserver?(event, fields)
            if event == "selection_action_dispatch" || event == "selection_action_failed" {
                completed.value = true
            }
        }
        defer { PerformanceDiagnostics.testObserver.value = previousObserver }

        store.requestCycle(forward: true)
        if phase != .resolving {
            try await waitUntil { store.items.count == 8 && (phase != .visible || store.isVisible) }
            store.selectedID = 2
        }
        store.commitSelection()
        try await waitUntil { completed.value }

        try expect(!store.isVisible, "confirmed app activation must not reopen the released switcher")
        try expect(!store.isSwitching)
        try expectEqual(showCount, phase == .visible ? 1 : 0, "a hidden release must never flash the panel")
        try expectEqual(activatedPIDs.value, [200])
        try expectEqual(tracker.recentWindowIDs, ranksBefore, "unverified selected-window focus must not change MRU")

        // Refresh the target app's real ordering: its other sibling is first.
        // The selected-but-unverified ID 2 must not get pinned by cache sync.
        catalog.visibleItems = [windows[2].withFrontmostState(true), windows[1].withFrontmostState(true)]
            + windows.filter { $0.pid != 200 }.map { $0.withFrontmostState(false) }
        let snapshotsBefore = catalog.visibleSnapshotCount
        store.requestCycle(forward: true)
        try await waitUntil { store.items.first?.id == 3 }
        try expect(catalog.visibleSnapshotCount > snapshotsBefore, "app-only multi-window completion needs fresh order")
        store.cancel()

        // A later external activation exposes the current-app history through
        // the previous-app shortcut. Both activations stay inside the seam.
        store.handleAppActivation(pid: 300)
        catalog.visibleItems = [makeItem(id: 30, pid: 300, isFrontmostApp: true, bundleIdentifier: "fixture.3"),
                                windows[1], windows[0].withFrontmostState(false)]
        await store.warmPreviewCache(context: "partial-history-check")
        let settings = SwitchBladeSettings.shared
        let wasEnabled = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = wasEnabled }
        store.switchToPreviousApplication()
        try await waitUntil { activatedPIDs.value.count == 2 }
        try expectEqual(activatedPIDs.value, [200, 200], "app-only completion must reconcile current-app history")
    }

    @MainActor private static func frontmostAppRequiresConfirmation() async throws {
        for confirmedActive in [false, true] {
            let activator = WindowActivator(
                raiseWindowOverride: { _ in false },
                activateApplicationOverride: { _ in false },
                isApplicationActiveOverride: { _ in confirmedActive }
            )
            try await visibleOutcome(activator: activator, targetIsFrontmost: true,
                                     shouldDismiss: confirmedActive)
        }
    }

    @MainActor private static func failedAppActivation() async throws {
        let activator = WindowActivator(raiseWindowOverride: { _ in false },
                                        activateApplicationOverride: { _ in false })
        try await visibleOutcome(activator: activator, targetIsFrontmost: false, shouldDismiss: false)
    }

    @MainActor private static func visibleOutcome(
        activator: WindowActivator, targetIsFrontmost: Bool, shouldDismiss: Bool
    ) async throws {
        let catalog = MockWindowCatalog()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let store = SwitcherStore(
            catalog: catalog, activator: activator, permissionService: MockPermissionService(),
            userDefaults: makeIsolatedUserDefaults(), mruTracker: tracker,
            workspaceNotificationCenter: NotificationCenter(),
            initialFrontmostAppPID: 100, switchBladePID: 999
        )
        defer { store.cancel() }
        catalog.visibleItems = [makeItem(id: 1, pid: 100, isFrontmostApp: true),
                                makeItem(id: 2, pid: targetIsFrontmost ? 100 : 200,
                                         isFrontmostApp: targetIsFrontmost)]
        await openSwitcher(store)
        try expect(store.isVisible)
        let ranksBefore = tracker.recentWindowIDs
        var showsAfterRelease = 0
        store.onShow = { showsAfterRelease += 1 }
        let completed = LockedValue(false)
        let previousObserver = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            previousObserver?(event, fields)
            if event == "selection_action_dispatch" || event == "selection_action_failed" { completed.value = true }
        }
        defer { PerformanceDiagnostics.testObserver.value = previousObserver }
        store.selectedID = 2
        store.commitSelection()
        try await waitUntil { completed.value }
        try expectEqual(store.isVisible, !shouldDismiss)
        try expectEqual(showsAfterRelease, shouldDismiss ? 0 : 1)
        try expectEqual(tracker.recentWindowIDs, ranksBefore)
    }

    @MainActor private static func newerExternalActivation() async throws {
        let catalog = MockWindowCatalog()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let started = LockedValue(false)
        let gate = DispatchSemaphore(value: 0)
        let completed = LockedValue(false)
        let activator = WindowActivator(
            raiseWindowOverride: { _ in false },
            activateApplicationOverride: { _ in
                started.value = true
                return gate.wait(timeout: .now() + 2) == .success
            }
        )
        let store = SwitcherStore(
            catalog: catalog, activator: activator, permissionService: MockPermissionService(),
            userDefaults: makeIsolatedUserDefaults(), mruTracker: tracker,
            focusedRankUpgradeDelayNanoseconds: 5_000_000_000,
            workspaceNotificationCenter: NotificationCenter(),
            initialFrontmostAppPID: 100, switchBladePID: 999
        )
        defer { gate.signal(); store.cancel() }
        catalog.visibleItems = [makeItem(id: 1, pid: 100, isFrontmostApp: true),
                                makeItem(id: 2, pid: 200), makeItem(id: 3, pid: 300)]
        let previousObserver = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            previousObserver?(event, fields)
            if event == "selection_action_dispatch" || event == "selection_action_failed" { completed.value = true }
        }
        defer { PerformanceDiagnostics.testObserver.value = previousObserver }
        await openSwitcher(store)
        store.selectedID = 2
        store.commitSelection()
        try await waitUntil { started.value }
        store.handleAppActivation(pid: 200)
        store.handleAppActivation(pid: 300)
        let ranksBeforeCompletion = tracker.recentWindowIDs
        gate.signal()
        try await waitUntil { completed.value }
        try expect(!store.isVisible)
        try expectEqual(tracker.recentWindowIDs, ranksBeforeCompletion)
        store.requestCycle(forward: true)
        try expectEqual(store.items.first?.id, 3, "partial completion must preserve newer external focus")
    }

    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(false, "operation did not reach the expected state")
    }
}
