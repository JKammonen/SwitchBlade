import AppKit
import Darwin
import Foundation
@testable import SwitchBladeCore

enum CaptureTimeoutTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("CaptureTimeout/sleepRaceFires_inBoundedTime", timeoutBounded),
        ("CaptureTimeout/softTimeoutHelper_timesOutWithoutWaitingForBlockedTask", softTimeoutHelper_timesOutWithoutWaitingForBlockedTask),
        ("CaptureTimeout/softTimeoutHelper_returnsCompletedValueForFastTask", softTimeoutHelper_returnsCompletedValueForFastTask),
        ("CaptureTimeout/softTimeoutHelper_stillTimesOutAfterParentCancellation", softTimeoutHelper_stillTimesOutAfterParentCancellation),
        ("ActivationRefresh/handleAppActivation_triggersCatalogRefresh", activationTriggersRefresh),
        ("ActivationRefresh/handleAppActivation_rewarmsPreviewCacheAfterInvalidation", activationRewarmsPreviewCacheAfterInvalidation),
        ("ActivationRefresh/doesNotUpdateMRUFromSystemActivation", activation_doesNotUpdateMRUFromSystemActivation),
        ("ActivationRefresh/selfInitiatedWindowSwitch_addsNoIdentityRank", activation_selfInitiatedWindowSwitchAddsNoIdentityRank),
        ("ActivationRefresh/externalActivation_upgradesToFocusedWindowRank", activation_externalActivationUpgradesToFocusedWindowRank),
        ("ActivationRefresh/warmupDoesNotPushSameAppSiblingToTail", activation_warmupDoesNotPushSameAppSiblingToTail),
        ("ActivationRefresh/skipsRefresh_whenSwitcherIdle", activation_skipsRefreshWhenIdle),
        ("CaptureInvalidation/storeForwardsLifecycleInvalidation", storeForwardsLifecycleInvalidation),
        ("CaptureStability/stableVisibleWindowIsAccepted", captureStability_stableVisibleWindowIsAccepted),
        ("CaptureStability/visibilityTransitionIsRejected", captureStability_visibilityTransitionIsRejected),
        ("CaptureStability/boundsTransitionIsRejected", captureStability_boundsTransitionIsRejected),
        ("CaptureStability/privacyOrIdentityTransitionIsRejected", captureStability_privacyOrIdentityTransitionIsRejected),
        ("CaptureStability/currentSpaceRejectsStableOffscreenWindow", captureStability_currentSpaceRejectsStableOffscreenWindow),
        ("CaptureStability/explicitOffscreenAllowanceIsExact", captureStability_explicitOffscreenAllowanceIsExact),
        ("CaptureStability/missingOnScreenStateRequiresExplicitAllowance", captureStability_missingOnScreenStateRequiresExplicitAllowance)
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

    /// A blocked detached task must not hold the caller hostage past the UX
    /// timeout. This is the guard that keeps stuck SCKit / CGWindowList work
    /// from stretching a canceled preview batch into a 30 s hang.
    static func softTimeoutHelper_timesOutWithoutWaitingForBlockedTask() async throws {
        let start = Date()
        let result = await SCContentCache.awaitTaskWithSoftTimeout(
            Task.detached(priority: .userInitiated) {
                usleep(200_000)
                return 7
            },
            timeoutMs: 50
        )
        let elapsedMs = Date().timeIntervalSince(start) * 1000

        switch result {
        case .timedOut:
            break
        case .completed:
            try expect(false, "blocked task should have timed out")
        }

        try expectGreaterThanOrEqual(elapsedMs, 45)
        try expectLessThan(elapsedMs, 160)
    }

    static func softTimeoutHelper_returnsCompletedValueForFastTask() async throws {
        let start = Date()
        let result = await SCContentCache.awaitTaskWithSoftTimeout(
            Task.detached(priority: .userInitiated) {
                42
            },
            timeoutMs: 100
        )
        let elapsedMs = Date().timeIntervalSince(start) * 1000

        switch result {
        case .completed(let value):
            try expectEqual(value, 42)
        case .timedOut:
            try expect(false, "fast task should have completed")
        }

        try expectLessThan(elapsedMs, 100)
    }

    static func softTimeoutHelper_stillTimesOutAfterParentCancellation() async throws {
        let start = Date()
        let parentTask = Task {
            await SCContentCache.awaitTaskWithSoftTimeout(
                Task.detached(priority: .userInitiated) {
                    usleep(200_000)
                    return 9
                },
                timeoutMs: 50
            )
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
        parentTask.cancel()
        let result = await parentTask.value
        let elapsedMs = Date().timeIntervalSince(start) * 1000

        switch result {
        case .timedOut:
            break
        case .completed:
            try expect(false, "timeout watcher should outlive parent cancellation")
        }

        try expectGreaterThanOrEqual(elapsedMs, 45)
        try expectLessThan(elapsedMs, 160)
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

    /// The background-preview invalidation must not strand the next switcher
    /// open in icon-only state for that app. App activation should trigger a
    /// preview warmup soon after the invalidation so the next cached open can
    /// already hydrate a real preview again.
    @MainActor static func activationRewarmsPreviewCacheAfterInvalidation() async throws {
        let settings = SwitchBladeSettings.shared
        let oldPreviewMode = settings.previewMode
        settings.previewMode = .livePreviews
        defer { settings.previewMode = oldPreviewMode }

        let preview = NSImage(size: CGSize(width: 12, height: 12))
        let (store, catalog, _, _) = makeStore(initialFrontmostAppPID: 100)
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, appName: "App A", title: "A", isFrontmostApp: true, bundleIdentifier: "com.example.a"),
            makeItem(id: 2, pid: 200, appName: "App B", title: "B", bundleIdentifier: "com.example.b")
        ]
        catalog.previewsToReturn = [1: preview]

        await store.warmPreviewCache(context: "seed")

        catalog.visibleItems = [
            makeItem(id: 2, pid: 200, appName: "App B", title: "B", isFrontmostApp: true, bundleIdentifier: "com.example.b"),
            makeItem(id: 1, pid: 100, appName: "App A", title: "A", bundleIdentifier: "com.example.a")
        ]
        let baselineCaptureCount = catalog.captureCallCount
        store.handleAppActivation(pid: 200)

        for _ in 0 ..< 120 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
            if catalog.captureCallCount > baselineCaptureCount { break }
        }
        await runPendingMainTasks()

        store.requestCycle(forward: true)
        await runPendingMainTasks()

        try expect(store.isVisible)
        try expectEqual(store.items.map(\.id), [2, 1])
        try expect(store.items.first(where: { $0.id == 1 })?.preview === preview)
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
        await openSwitcher(store)         // becomes visible
        store.selectedID = 2
        store.commitSelection()
        await runPendingMainTasks()       // hidden again, MRU now [2, ...]

        // App activation alone should not move pid=300 ahead of id=2. It marks
        // the cache for resnapshot, so the next open re-reads fresh.
        store.handleAppActivation(pid: 300)
        await openSwitcher(store)
        try expectEqual(store.items.map(\.id), [1, 2, 3])
    }

    /// The activation notification for a window SwitchBlade itself just
    /// activated must not stack an identity-only rank on top of the concrete
    /// rank rememberSelection recorded at commit — nor kick the AX upgrade.
    @MainActor static func activation_selfInitiatedWindowSwitchAddsNoIdentityRank() async throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let (store, catalog, _, _) = makeStore(mruTracker: tracker)
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, appName: "Editor", isFrontmostApp: true, bundleIdentifier: "com.example.editor"),
            makeItem(id: 2, pid: 200, appName: "Browser", bundleIdentifier: "com.example.browser"),
            makeItem(id: 3, pid: 200, appName: "Browser", bundleIdentifier: "com.example.browser")
        ]
        await openSwitcher(store)
        store.selectedID = 2
        store.commitSelection()
        await runPendingMainTasks()

        store.handleAppActivation(pid: 200)
        await runPendingMainTasks()

        try expectEqual(tracker.recentWindowIDs.first, 2)
        try expectEqual(tracker.identityOnlyRankIdentities, [])
        try expectEqual(catalog.focusedWindowItemCallCount, 0)
    }

    /// An external activation (click, Dock) names only the app. The store
    /// records the coarse identity rank immediately, then upgrades it to the
    /// AX-resolved focused window so multi-window apps gain per-window rank.
    @MainActor static func activation_externalActivationUpgradesToFocusedWindowRank() async throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let (store, catalog, _, _) = makeStore(mruTracker: tracker)
        let focused = makeItem(id: 31, pid: 300, appName: "Notes", title: "Plan", bundleIdentifier: "com.example.notes")
        catalog.focusedWindowItemsByPID[300] = focused

        store.handleAppActivation(pid: 300)
        await runPendingMainTasks()

        try expectEqual(tracker.recentWindowIDs.first, 31)
        try expectEqual(tracker.identityOnlyRankIdentities, [])
        try expectEqual(tracker.recentBundleIDs.first, "com.example.notes")
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
        await seedOpenItemsCache(store)

        let baselineSnapshots = catalog.visibleSnapshotCount

        // Warmup snapshot drifts the sibling behind another app even though the
        // cached order from the last real open was [1, 2, 3].
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, title: "Ghostty B", isFrontmostApp: true),
            makeItem(id: 3, pid: 200, title: "Other App"),
            makeItem(id: 2, pid: 100, title: "Ghostty A")
        ]
        store.handleAppActivation(pid: 100)

        // Wait on the open-items warmup's own snapshot — the event that actually
        // stabilizes cachedOpenItems — not the content-cache refresh, which is a
        // separate task that can finish first and leave the cache un-stabilized.
        for _ in 0 ..< 120 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
            if catalog.visibleSnapshotCount > baselineSnapshots { break }
        }
        // Let the warmup task's continuation (order + stabilize + cache update)
        // run after its snapshot returned, before the open reads the cache.
        await runPendingMainTasks()

        store.requestCycle(forward: true)
        await runPendingMainTasks()

        try expect(store.isVisible)
        try expectEqual(store.items.map(\.id), [1, 2, 3])
        try expectEqual(
            catalog.visibleSnapshotCount,
            baselineSnapshots + 2,
            "current-app multi-window open should validate the warm cache before showing it"
        )
    }

    @MainActor static func storeForwardsLifecycleInvalidation() async throws {
        let (store, catalog, _, _) = makeStore()

        await store.invalidateCaptureCache(reason: "test display change")

        try expectEqual(catalog.invalidateContentCacheCallCount, 1)
        try expectEqual(catalog.lastInvalidationReason, "test display change")
    }

    static func captureStability_stableVisibleWindowIsAccepted() async throws {
        let state = captureState()
        let accepted = PreviewCaptureStabilityPolicy.acceptedWindowIDs(
            capturedWindowIDs: [1],
            before: [1: state],
            after: [1: state],
            scope: .currentSpace
        )

        try expectEqual(accepted, Set([CGWindowID(1)]))
    }

    static func captureStability_visibilityTransitionIsRejected() async throws {
        let visible = captureState(isOnScreen: true)
        let offscreen = captureState(isOnScreen: false)

        let minimizing = PreviewCaptureStabilityPolicy.acceptedWindowIDs(
            capturedWindowIDs: [1],
            before: [1: visible],
            after: [1: offscreen],
            scope: .currentSpace
        )
        let restoring = PreviewCaptureStabilityPolicy.acceptedWindowIDs(
            capturedWindowIDs: [1],
            before: [1: offscreen],
            after: [1: visible],
            scope: .currentSpace
        )

        try expect(minimizing.isEmpty, "minimization transition frame must be rejected")
        try expect(restoring.isEmpty, "restore transition frame must be rejected")
    }

    static func captureStability_boundsTransitionIsRejected() async throws {
        let before = captureState(bounds: CGRect(x: 100, y: 100, width: 1200, height: 800))
        let after = captureState(bounds: CGRect(x: 140, y: 120, width: 1160, height: 760))
        let accepted = PreviewCaptureStabilityPolicy.acceptedWindowIDs(
            capturedWindowIDs: [1],
            before: [1: before],
            after: [1: after],
            scope: .currentSpace
        )

        try expect(accepted.isEmpty, "a moving or resizing window must not replace a stable preview")
    }

    static func captureStability_privacyOrIdentityTransitionIsRejected() async throws {
        let before = captureState(ownerPID: 42, sharingState: 1)
        let privateAfter = captureState(ownerPID: 42, sharingState: 0)
        let reusedIDAfter = captureState(ownerPID: 84, sharingState: 1)

        let privateCapture = PreviewCaptureStabilityPolicy.acceptedWindowIDs(
            capturedWindowIDs: [1],
            before: [1: before],
            after: [1: privateAfter],
            scope: .currentSpace
        )
        let reusedIDCapture = PreviewCaptureStabilityPolicy.acceptedWindowIDs(
            capturedWindowIDs: [1],
            before: [1: before],
            after: [1: reusedIDAfter],
            scope: .currentSpace
        )

        try expect(privateCapture.isEmpty, "a newly-private window must reject the captured frame")
        try expect(reusedIDCapture.isEmpty, "a reused window id must reject the captured frame")
    }

    static func captureStability_currentSpaceRejectsStableOffscreenWindow() async throws {
        let offscreen = captureState(isOnScreen: false)
        let currentSpace = PreviewCaptureStabilityPolicy.acceptedWindowIDs(
            capturedWindowIDs: [1],
            before: [1: offscreen],
            after: [1: offscreen],
            scope: .currentSpace
        )
        let allSpaces = PreviewCaptureStabilityPolicy.acceptedWindowIDs(
            capturedWindowIDs: [1],
            before: [1: offscreen],
            after: [1: offscreen],
            scope: .allSpaces
        )

        try expect(currentSpace.isEmpty)
        try expectEqual(allSpaces, Set([CGWindowID(1)]))
    }

    static func captureStability_explicitOffscreenAllowanceIsExact() async throws {
        let offscreen = captureState(isOnScreen: false)
        let accepted = PreviewCaptureStabilityPolicy.acceptedWindowIDs(
            capturedWindowIDs: [1, 2],
            before: [1: offscreen, 2: offscreen],
            after: [1: offscreen, 2: offscreen],
            scope: .currentSpace,
            allowedOffscreenWindowIDs: [1]
        )
        let moved = captureState(
            bounds: CGRect(x: 120, y: 100, width: 1200, height: 800),
            isOnScreen: false
        )
        let unstable = PreviewCaptureStabilityPolicy.acceptedWindowIDs(
            capturedWindowIDs: [1],
            before: [1: offscreen],
            after: [1: moved],
            scope: .currentSpace,
            allowedOffscreenWindowIDs: [1]
        )

        try expectEqual(accepted, Set([CGWindowID(1)]))
        try expect(unstable.isEmpty, "offscreen allowance must not bypass transition checks")
    }

    static func captureStability_missingOnScreenStateRequiresExplicitAllowance() async throws {
        try expectNil(PreviewCaptureStabilityPolicy.onScreenState(
            rawValue: nil,
            allowMissingAsOffscreen: false
        ))
        try expectEqual(
            PreviewCaptureStabilityPolicy.onScreenState(
                rawValue: nil,
                allowMissingAsOffscreen: true
            ),
            false
        )
        try expectEqual(
            PreviewCaptureStabilityPolicy.onScreenState(
                rawValue: true,
                allowMissingAsOffscreen: false
            ),
            true
        )
    }

    private static func captureState(
        ownerPID: pid_t = 42,
        bounds: CGRect = CGRect(x: 100, y: 100, width: 1200, height: 800),
        isOnScreen: Bool = true,
        sharingState: Int = 1
    ) -> PreviewCaptureWindowState {
        PreviewCaptureWindowState(
            ownerPID: ownerPID,
            bounds: bounds,
            isOnScreen: isOnScreen,
            sharingState: sharingState,
            alpha: 1
        )
    }
}
