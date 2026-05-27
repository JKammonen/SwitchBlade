import AppKit
import Foundation
@testable import SwitchBladeCore

enum CaptureTimeoutTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("CaptureTimeout/sleepRaceFires_inBoundedTime", timeoutBounded),
        ("ActivationRefresh/handleAppActivation_triggersCatalogRefresh", activationTriggersRefresh),
        ("ActivationRefresh/doesNotUpdateMRUFromSystemActivation", activation_doesNotUpdateMRUFromSystemActivation),
        ("ActivationRefresh/warmupDoesNotPushSameAppSiblingToTail", activation_warmupDoesNotPushSameAppSiblingToTail),
        ("ActivationRefresh/skipsRefresh_whenSwitcherIdle", activation_skipsRefreshWhenIdle),
        ("CaptureInvalidation/storeForwardsLifecycleInvalidation", storeForwardsLifecycleInvalidation)
    ]

    /// We can't invoke captureWithSoftTimeout against a real SCWindow from
    /// tests, but we can verify the Task.sleep timing primitive it uses for
    /// its UX bound.
    static func timeoutBounded() async throws {
        let start = Date()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        try expectGreaterThanOrEqual(elapsedMs, 45)
        try expectLessThan(elapsedMs, 250)
    }

    /// Calls SwitcherStore.handleAppActivation directly (same entry point the
    /// NSWorkspace observer uses) and verifies the catalog gets an opportunistic
    /// `refreshContentCacheIfStale` kick. This is the path that keeps the SCKit
    /// cache warm whenever the user is switching between apps. The refresh is
    /// delayed briefly so the newly-active app has finished settling.
    @MainActor static func activationTriggersRefresh() async throws {
        let (store, catalog, _, _) = makeStore()
        let baseline = catalog.refreshIfStaleCallCount

        store.handleAppActivation(pid: 1234)

        // The warmup is deliberately debounced by 250 ms.
        for _ in 0 ..< 80 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
            if catalog.refreshIfStaleCallCount > baseline { break }
        }

        try expectGreaterThan(catalog.refreshIfStaleCallCount, baseline)
    }

    /// If the user hasn't used Cmd+Tab in `activationWarmupWindow`, app
    /// activations stop triggering the SCKit warmup. Cost is genuinely zero
    /// for idle users.
    @MainActor static func activation_skipsRefreshWhenIdle() async throws {
        // 50 ms warmup window — long enough to let the constructor-set
        // `lastSwitcherUse = Date()` count as "recent", short enough to expire
        // before the test's wait.
        let (store, catalog, _, _) = makeStore(activationWarmupWindow: 0.05)
        try? await Task.sleep(nanoseconds: 80_000_000) // 80 ms — outside the window

        let baseline = catalog.refreshIfStaleCallCount
        store.handleAppActivation(pid: 1234)

        // Drain enough time for any (unwanted) detached refresh to land.
        for _ in 0 ..< 20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        try expectEqual(catalog.refreshIfStaleCallCount, baseline,
                        "warmup gate should have blocked the refresh")
    }

    /// System activation gives us only an app PID, not a concrete window. It
    /// must not reshuffle the per-window MRU order.
    @MainActor static func activation_doesNotUpdateMRUFromSystemActivation() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200),
            makeItem(id: 3, pid: 300)
        ]
        store.cycle(forward: true)        // becomes visible
        store.selectedID = 2
        store.commitSelection()
        await runPendingMainTasks()       // hidden again, MRU now [2, ...]

        // App activation alone should not move pid=300 ahead of id=2.
        store.handleAppActivation(pid: 300)
        store.cycle(forward: true)
        try expectEqual(store.items.map(\.id), [1, 2, 3])
    }

    /// Regression guard: the post-activation open-items warmup is a background
    /// cache refresh, not an authoritative reorder. If it sees the frontmost
    /// app's sibling window later in the raw snapshot, it must not push that
    /// sibling behind other apps in the next cached open.
    @MainActor static func activation_warmupDoesNotPushSameAppSiblingToTail() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, title: "Ghostty B", isFrontmostApp: true),
            makeItem(id: 2, pid: 100, title: "Ghostty A"),
            makeItem(id: 3, pid: 200, title: "Other App")
        ]
        store.cycle(forward: true)
        store.cancel()

        let baselineSnapshots = catalog.visibleSnapshotCount

        // Warmup snapshot drifts the sibling behind another app even though the
        // cached order from the last real open was [1, 2, 3].
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, title: "Ghostty B", isFrontmostApp: true),
            makeItem(id: 3, pid: 200, title: "Other App"),
            makeItem(id: 2, pid: 100, title: "Ghostty A")
        ]
        store.handleAppActivation(pid: 100)

        for _ in 0 ..< 80 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
            if catalog.refreshIfStaleCallCount > 0 { break }
        }

        store.requestCycle(forward: true)
        await runPendingMainTasks()

        try expect(!store.isVisible)
        try? await Task.sleep(nanoseconds: 130_000_000)
        await runPendingMainTasks()

        try expect(store.isVisible)
        try expectEqual(store.items.map(\.id), [1, 2, 3])
        try expectEqual(catalog.visibleSnapshotCount, baselineSnapshots + 1)
    }

    @MainActor static func storeForwardsLifecycleInvalidation() async throws {
        let (store, catalog, _, _) = makeStore()

        await store.invalidateCaptureCache(reason: "test display change")

        try expectEqual(catalog.invalidateContentCacheCallCount, 1)
        try expectEqual(catalog.lastInvalidationReason, "test display change")
    }
}
