import AppKit
import Carbon.HIToolbox
@testable import SwitchBladeCore

enum SwitcherStoreTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        // cycle / show
        ("Store/cycle_whenNotVisible_showsPanel", cycle_showsPanel),
        ("Store/cycle_whenNotVisible_emptySnapshot_doesNotShow", cycle_emptyNoShow),
        ("Store/cycle_whenNotVisible_preselectsSecondItem", cycle_preselectsSecond),
        ("Store/cycle_whenNotVisible_singleItem_selectsIt", cycle_singleItem),
        ("Store/cycle_whenVisible_movesForward", cycle_visibleForward),
        ("Store/cycle_whenVisible_movesBackward_wraps", cycle_visibleBackwardWraps),
        ("Store/cycle_selectionWrapsAtEnd", cycle_selectionWraps),
        ("Store/requestCycle_marksSwitchingSynchronously", requestCycle_marksSwitchingSynchronously),
        ("Store/requestCycle_fastReleaseCommitsWithoutShowingPanel", requestCycle_fastReleaseCommitsWithoutShowingPanel),
        ("Store/requestCycle_doubleCallDroppedWhenAlreadySwitching", requestCycle_doubleCallDropped),
        ("Store/requestCycle_usesCachedItemsWithoutSnapshot", requestCycle_usesCachedItemsWithoutSnapshot),
        ("Store/requestCycle_bypassesFreshCacheAfterExternalActivation", requestCycle_bypassesFreshCacheAfterExternalActivation),
        ("Store/requestCycle_rebasesFreshCacheAfterSingleWindowExternalActivation", requestCycle_rebasesFreshCacheAfterSingleWindowExternalActivation),
        ("Store/requestCycle_backgroundedAppKeepsCachedPreviewAfterExternalActivation", requestCycle_backgroundedAppKeepsCachedPreviewAfterExternalActivation),
        ("Store/requestCycle_cachedSecondTabMovesSelectionBeforePanelShows", requestCycle_cachedSecondTabMovesSelectionBeforePanelShows),
        ("Store/requestCycle_immediateReopenAfterCommitUsesUpdatedCachedOrder", requestCycle_immediateReopenAfterCommitUsesUpdatedCachedOrder),
        ("Store/requestCycle_reusesInFlightWarmupSnapshot", requestCycle_reusesInFlightWarmupSnapshot),
        ("Store/requestCycle_slowSnapshotDoesNotPaySecondPanelDelay", requestCycle_slowSnapshotDoesNotPaySecondPanelDelay),
        ("Store/requestCycle_usesStaleCachedItemsImmediatelyThenRefreshes", requestCycle_usesStaleCachedItemsImmediatelyThenRefreshes),
        ("Store/requestCycle_staleRefreshDoesNotShowVisiblePanelAgain", requestCycle_staleRefreshDoesNotShowVisiblePanelAgain),
        ("Store/requestCycle_staleCachedOpenHealsCacheEvenAfterImmediateCommit", requestCycle_staleCachedOpenHealsCacheEvenAfterImmediateCommit),
        ("Store/requestCycle_staleSameAppQuickReleaseWaitsForFreshSnapshot", requestCycle_staleSameAppQuickReleaseWaitsForFreshSnapshot),
        ("Store/cachedDelayPath_mergesMinimizedAfterPanelShow", cachedDelayPath_mergesMinimized),
        ("Store/minimizedMerge_keepsSyntheticWindowAtMRURank", minimizedMerge_keepsSyntheticWindowAtMRURank),
        ("Store/minimizedMerge_redactedTitleShowsAppOnly", minimizedMerge_redactedTitleShowsAppOnly),
        // ordering
        ("Store/ordering_putsFrontmostAppFirst", ordering_frontmost),
        ("Store/ordering_recentlyUsedAfterFrontmost", ordering_recent),
        ("Store/ordering_alphabeticalKeepsFrontmostFirst", ordering_alphabeticalKeepsFrontmostFirst),
        ("Store/ordering_appGroupedKeepsFrontmostFirst", ordering_appGroupedKeepsFrontmostFirst),
        // preview modes
        ("Store/previewMode_iconsOnlySkipsCaptures", previewMode_iconsOnlySkipsCaptures),
        ("Store/previewCapture_skipsUncapturableItems", previewCapture_skipsUncapturableItems),
        ("Store/previewCapture_limitsDeferredBatch", previewCapture_limitsDeferredBatch),
        ("Store/previewCapture_skipsCachedDeferredItems", previewCapture_skipsCachedDeferredItems),
        ("Store/warmPreviewCache_populatesFirstOpen", warmPreviewCache_populatesFirstOpen),
        ("Store/warmPreviewCache_primesHiddenDisplayItems", warmPreviewCache_primesHiddenDisplayItems),
        ("Store/warmPreviewCache_limitsBackgroundCaptureBatch", warmPreviewCache_limitsBackgroundCaptureBatch),
        ("Store/warmPreviewCache_iconsOnlySkipsCaptures", warmPreviewCache_iconsOnlySkipsCaptures),
        // handleKeyDown
        ("Store/handleKeyDown_whenNotVisible_false", handleKeyDown_notVisible),
        ("Store/handleKeyDown_tab_forward", handleKeyDown_tabForward),
        ("Store/handleKeyDown_shiftTab_backward", handleKeyDown_shiftTabBackward),
        ("Store/handleKeyDown_arrows_move", handleKeyDown_arrows),
        ("Store/handleKeyDown_return_commits", handleKeyDown_returnCommits),
        ("Store/handleKeyDown_escape_cancels", handleKeyDown_escape),
        ("Store/handleKeyDown_unknownKey_false", handleKeyDown_unknown),
        ("Store/handleKeyDown_home_selectsFirst", handleKeyDown_home),
        ("Store/handleKeyDown_end_selectsLast", handleKeyDown_end),
        ("Store/handleKeyDown_cmdQ_quitsSelectedApp", handleKeyDown_cmdQ),
        ("Store/handleKeyDown_cmdH_hidesSelectedApp", handleKeyDown_cmdH),
        ("Store/handleKeyDown_cmdComma_opensSettings", handleKeyDown_cmdComma),
        ("Store/handleKeyDown_optionArrow_snapsSelectedWindow", handleKeyDown_optionArrowSnaps),
        ("Store/quit_removesAllWindowsOfThatPid", quit_removesAllPidWindows),
        ("Store/switchToPreviousApplication_activatesPreviousPid", switchToPreviousApplication_activatesPreviousPid),
        ("Store/switchToPreviousApplication_disabledSetting_skipsActivation", switchToPreviousApplication_disabledSetting),
        ("Store/switchToPreviousApplication_infersPreviousPidWhenUntracked", switchToPreviousApplication_infersPreviousPid),
        ("Store/switchToPreviousApplication_sameAppWindowsBounceInsteadOfPickingOtherApp", switchToPreviousApplication_sameAppWindowsBounceInsteadOfPickingOtherApp),
        ("Store/switchToPreviousApplication_usesSnapshotCurrentPidWhenTrackedPidIsStale", switchToPreviousApplication_usesSnapshotCurrentPidWhenTrackedPidIsStale),
        ("Store/switchToPreviousApplication_repeatedCallsCanBounceBetweenTwoApps", switchToPreviousApplication_bouncesBetweenTwoApps),
        ("Store/switchToPreviousApplication_concurrentGestureDropped", switchToPreviousApplication_concurrentGestureDropped),
        ("Store/switchToPreviousApplication_singleWindowCachedPreviousPidSkipsSnapshot", switchToPreviousApplication_singleWindowCachedPreviousPidSkipsSnapshot),
        ("Store/handleModifierMouseSwitch_visible_commitsSelection", handleModifierMouseSwitch_visibleCommitsSelection),
        ("Store/snap_item_hidesAndRoutesToActivator", snap_itemRoutesToActivator),
        // commit / cancel
        ("Store/commitSelection_activatesAndHides", commit_activates),
        ("Store/commitSelection_dispatchesActivationSynchronously", commit_dispatchesActivationSynchronously),
        ("Store/commitSelection_withNoSelection_hides", commit_noSelection),
        ("Store/cancel_hidesWithoutActivating", cancel_hides),
        // close
        ("Store/close_callsActivator_removesFromItems", close_callsActivator),
        ("Store/close_lastItem_hidesPanel", close_lastItem),
        ("Store/close_selectedItem_picksNeighbor", close_picksNeighbor),
        // hover
        ("Store/hover_isIgnoredImmediatelyAfterShow", hover_ignoredInitially),
        // choose
        ("Store/choose_setsSelectionAndCommits", choose_commits)
    ]

    // MARK: cycle / show

    @MainActor static func cycle_showsPanel() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        var onShowCalls = 0
        store.onShow = { onShowCalls += 1 }

        await openSwitcher(store)

        try expect(store.isVisible)
        try expectEqual(store.items.count, 3)
        try expectEqual(catalog.visibleSnapshotCount, 1)
        try expectEqual(onShowCalls, 1)
    }

    @MainActor static func cycle_emptyNoShow() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = []
        var onShowCalls = 0
        store.onShow = { onShowCalls += 1 }

        store.requestCycle(forward: true)
        await runPendingMainTasks()

        try expect(!store.isVisible)
        try expect(store.items.isEmpty)
        try expectEqual(onShowCalls, 0)
    }

    @MainActor static func cycle_preselectsSecond() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)
        try expectEqual(store.selectedID, 2)
    }

    @MainActor static func cycle_singleItem() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [makeItem(id: 1, isFrontmostApp: true)]
        await openSwitcher(store)
        try expectEqual(store.selectedID, 1)
    }

    @MainActor static func cycle_visibleForward() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)               // selected = 2
        store.cycle(forward: true)
        try expectEqual(store.selectedID, 3)
    }

    @MainActor static func cycle_visibleBackwardWraps() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)               // selected = 2
        store.cycle(forward: false)             // → 1
        store.cycle(forward: false)             // wraps → 3
        try expectEqual(store.selectedID, 3)
    }

    @MainActor static func cycle_selectionWraps() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        await openSwitcher(store)               // selected = 2
        store.cycle(forward: true)              // wraps → 1
        try expectEqual(store.selectedID, 1)
        store.cycle(forward: true)              // → 2
        try expectEqual(store.selectedID, 2)
    }

    @MainActor static func requestCycle_marksSwitchingSynchronously() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]

        store.requestCycle(forward: true)

        try expect(store.isSwitching, "event-tap path should mark release tracking before async open work runs")
        try expect(!store.isVisible, "cache-miss path should not synchronously show before the off-main snapshot returns")
        try expectEqual(catalog.visibleSnapshotCount, 0)
        await runPendingMainTasks()
    }

    @MainActor static func requestCycle_fastReleaseCommitsWithoutShowingPanel() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        var onShowCalls = 0
        store.onShow = { onShowCalls += 1 }

        store.requestCycle(forward: true)
        store.commitSelection()
        await runPendingMainTasks()

        try expectEqual(activator.activatedItems.map(\.id), [2])
        try expect(!store.isVisible)
        try expectEqual(onShowCalls, 0)
        try expectEqual(catalog.captureCallCount, 0)
    }

    @MainActor static func requestCycle_doubleCallDropped() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]

        store.requestCycle(forward: true)
        // Second call while isSwitching=true should be dropped — only one cycle() task fires.
        store.requestCycle(forward: true)

        await runPendingMainTasks()
        try? await Task.sleep(nanoseconds: 130_000_000)
        await runPendingMainTasks()

        // Panel opened exactly once: one items load, one show.
        try expect(store.isVisible)
        try expectEqual(store.items.count, 2)
    }

    @MainActor static func requestCycle_usesCachedItemsWithoutSnapshot() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        await seedOpenItemsCache(store)

        let baselineSnapshots = catalog.visibleSnapshotCount
        catalog.visibleItems = [
            makeItem(id: 3, isFrontmostApp: true),
            makeItem(id: 4)
        ]

        store.requestCycle(forward: true)

        try expect(store.isSwitching)
        try expect(store.isVisible, "cached request should show immediately once the warm item list is ready")
        try expectEqual(catalog.visibleSnapshotCount, baselineSnapshots)

        try expectEqual(store.items.map(\.id), [1, 2])
        try expectEqual(catalog.visibleSnapshotCount, baselineSnapshots)
    }

    @MainActor static func requestCycle_bypassesFreshCacheAfterExternalActivation() async throws {
        let (store, catalog, _, _) = makeStore(activationWarmupWindow: -1)
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200)
        ]
        await seedOpenItemsCache(store)

        let baselineSnapshots = catalog.visibleSnapshotCount
        catalog.visibleItems = [
            makeItem(id: 3, pid: 300, isFrontmostApp: true),
            makeItem(id: 4, pid: 100)
        ]
        store.handleAppActivation(pid: 300)

        store.requestCycle(forward: true)

        try expect(store.isSwitching)
        try expect(!store.isVisible, "fresh snapshot path should still keep the quick-release window hidden at first")

        try? await Task.sleep(nanoseconds: 130_000_000)
        await runPendingMainTasks()

        try expect(store.isVisible)
        try expectEqual(store.items.map(\.id), [3, 4])
        try expectEqual(catalog.visibleSnapshotCount, baselineSnapshots + 1)
    }

    @MainActor static func requestCycle_rebasesFreshCacheAfterSingleWindowExternalActivation() async throws {
        let (store, catalog, _, _) = makeStore(
            activationWarmupWindow: -1,
            initialFrontmostAppPID: 100
        )
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200)
        ]
        await seedOpenItemsCache(store)

        catalog.visibleSnapshotDelayNanoseconds = 200_000_000
        let baselineSnapshots = catalog.visibleSnapshotCount
        store.handleAppActivation(pid: 200)

        store.requestCycle(forward: true)

        try expect(store.isVisible, "single-window rebased cache should show without waiting for a fresh snapshot")
        try expectEqual(store.items.map(\.id), [2, 1])
        try expectEqual(store.items.map(\.isFrontmostApp), [true, false])
        try expectEqual(store.selectedID, 1)
        try expect(
            catalog.visibleSnapshotCount <= baselineSnapshots + 1,
            "background cache healing may start, but the panel must not wait for it"
        )
    }

    @MainActor static func requestCycle_backgroundedAppKeepsCachedPreviewAfterExternalActivation() async throws {
        let settings = SwitchBladeSettings.shared
        let oldPreviewMode = settings.previewMode
        settings.previewMode = .livePreviews
        defer { settings.previewMode = oldPreviewMode }

        let preview = NSImage(size: CGSize(width: 10, height: 10))
        let (store, catalog, _, _) = makeStore(
            activationWarmupWindow: -1,
            initialFrontmostAppPID: 100
        )
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, appName: "Safari", title: "Tab A", isFrontmostApp: true, bundleIdentifier: "com.apple.Safari"),
            makeItem(id: 2, pid: 200, appName: "Notes", title: "Note", bundleIdentifier: "com.apple.Notes")
        ]
        catalog.previewsToReturn = [1: preview]

        await store.warmPreviewCache(context: "seed")
        store.requestCycle(forward: true)
        await runPendingMainTasks()
        try expect(store.items.first(where: { $0.id == 1 })?.preview === preview)

        store.cancel()
        await runPendingMainTasks()

        catalog.previewsToReturn = [:]
        catalog.visibleItems = [
            makeItem(id: 2, pid: 200, appName: "Notes", title: "Note", isFrontmostApp: true, bundleIdentifier: "com.apple.Notes"),
            makeItem(id: 1, pid: 100, appName: "Safari", title: "Tab A", bundleIdentifier: "com.apple.Safari")
        ]
        store.handleAppActivation(pid: 200)
        store.requestCycle(forward: true)
        await runPendingMainTasks()

        try expect(store.isVisible)
        try expectEqual(store.items.map(\.id), [2, 1])
        // Stale-while-revalidate: the backgrounded app keeps its cached preview so
        // the next open shows it instantly instead of flashing an icon. With warmup
        // disabled and no fresh capture available, the cached image must still be
        // present (a later capture would replace it in place).
        try expect(
            store.items.first(where: { $0.id == 1 })?.preview === preview,
            "backgrounded app should keep showing its cached preview, not blank to an icon"
        )
    }

    // Regression guard for "minimized windows do not appear in the switcher":
    // the cached open path delays panel show by initialPanelShowDelayNanoseconds.
    // Previously, mergeGeneration was captured BEFORE showWithPreviews ran
    // (in the delay path), so the eventual merge-guard `previewGeneration ==
    // generation` always failed and minimized never merged. Now the merge is
    // scheduled inside showWithPreviews so the captured generation matches.
    @MainActor static func cachedDelayPath_mergesMinimized() async throws {
        let (store, catalog, _, _) = makeStore(initialPanelShowDelayNanoseconds: 120_000_000)
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        catalog.minimizedItems = [
            makeItem(id: 99, isMinimized: true)
        ]
        // Prime cachedOpenItems via a full open + cancel cycle.
        await seedOpenItemsCache(store)

        // requestCycle now uses the cached path with delayPanelShow=true.
        store.requestCycle(forward: true)

        // Wait past the panel-show delay so showWithPreviews has fired and
        // scheduleMinimizedMerge has captured the post-increment generation.
        try? await Task.sleep(nanoseconds: 200_000_000)
        await runPendingMainTasks()

        try expect(store.isVisible)
        try expect(
            store.items.contains(where: { $0.id == 99 }),
            "minimized window must merge into items after the delayed cached open"
        )
    }

    @MainActor static func minimizedMerge_keepsSyntheticWindowAtMRURank() async throws {
        let userDefaults = makeIsolatedUserDefaults()
        let catalog = MockWindowCatalog()
        let activator = MockWindowActivator()
        let permissions = MockPermissionService()
        let mruTracker = MRUTracker(userDefaults: userDefaults)

        let frontmost = makeItem(
            id: 1,
            pid: 100,
            appName: "Safari",
            title: "Docs",
            isFrontmostApp: true,
            bundleIdentifier: "com.apple.Safari"
        )
        let teamsVisible = makeItem(
            id: 10,
            pid: 81772,
            appName: "Microsoft Teams",
            title: "Daily",
            bundleIdentifier: "com.microsoft.teams2"
        )
        let codex = makeItem(
            id: 2,
            pid: 200,
            appName: "Codex",
            title: "Work",
            bundleIdentifier: "com.openai.codex"
        )
        let claude = makeItem(
            id: 3,
            pid: 300,
            appName: "Claude",
            title: "Notes",
            bundleIdentifier: "com.anthropic.claude"
        )
        mruTracker.rememberSelection(teamsVisible.id, in: [frontmost, teamsVisible, codex, claude])

        let store = SwitcherStore(
            catalog: catalog,
            activator: activator,
            permissionService: permissions,
            userDefaults: userDefaults,
            mruTracker: mruTracker,
            initialFrontmostAppPID: frontmost.pid,
            switchBladePID: 999
        )
        let syntheticTeamsID = SyntheticWindowID.make(pid: teamsVisible.pid, index: 0, title: teamsVisible.title)
        let minimizedTeams = makeItem(
            id: syntheticTeamsID,
            pid: teamsVisible.pid,
            appName: teamsVisible.appName,
            title: teamsVisible.title,
            isMinimized: true,
            canCapturePreview: false,
            bundleIdentifier: teamsVisible.bundleIdentifier
        )

        catalog.visibleItems = [frontmost, codex, claude]
        catalog.minimizedItems = [minimizedTeams]

        await openSwitcher(store)
        for _ in 0 ..< 60 where !store.items.contains(where: { $0.id == syntheticTeamsID }) {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        try expectEqual(
            store.items.map(\.id),
            [frontmost.id, syntheticTeamsID, codex.id, claude.id],
            "a synthetic minimized row with an existing MRU signature must not append to the tail"
        )
        try expectEqual(
            store.selectedID,
            syntheticTeamsID,
            "automatic default selection should follow the new MRU order after minimized merge"
        )
    }

    @MainActor static func minimizedMerge_redactedTitleShowsAppOnly() async throws {
        let (store, catalog, _, _) = makeStore()
        let frontmost = makeItem(
            id: 1,
            pid: 100,
            appName: "Safari",
            title: "Docs",
            isFrontmostApp: true,
            bundleIdentifier: "com.apple.Safari"
        )
        let syntheticMailID = SyntheticWindowID.make(pid: 200, index: 0, title: "Private Subject")
        let minimizedMail = makeItem(
            id: syntheticMailID,
            pid: 200,
            appName: "Mail",
            title: "Private Subject",
            isMinimized: true,
            canCapturePreview: false,
            isTitleRedacted: true,
            bundleIdentifier: "com.apple.mail"
        )
        catalog.visibleItems = [frontmost]
        catalog.minimizedItems = [minimizedMail]

        await openSwitcher(store)
        for _ in 0 ..< 60 where !store.items.contains(where: { $0.id == syntheticMailID }) {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        guard let merged = store.items.first(where: { $0.id == syntheticMailID }) else {
            try expect(false, "redacted minimized window must merge into switcher")
            return
        }
        try expectEqual(merged.title, "Private Subject")
        try expectEqual(merged.displayTitle, "Mail")
        try expectEqual(merged.subtitle, "App")
        try expect(!merged.canCapturePreview)
        try expectNil(merged.preview)
    }

    @MainActor static func requestCycle_cachedSecondTabMovesSelectionBeforePanelShows() async throws {
        let (store, catalog, _, _) = makeStore(initialPanelShowDelayNanoseconds: 120_000_000)
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await seedOpenItemsCache(store)

        let baselineSnapshots = catalog.visibleSnapshotCount

        store.requestCycle(forward: true)
        try expect(!store.isVisible)
        try expectEqual(store.selectedID, 2)

        store.requestCycle(forward: true)
        try expectEqual(store.selectedID, 3)
        try expect(store.isVisible, "second Tab while panel show is delayed should force the panel visible")
        try expectEqual(catalog.visibleSnapshotCount, baselineSnapshots)

        try? await Task.sleep(nanoseconds: 130_000_000)
        await runPendingMainTasks()

        try expect(store.isVisible)
        try expectEqual(store.selectedID, 3)
    }

    @MainActor static func requestCycle_immediateReopenAfterCommitUsesUpdatedCachedOrder() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200),
            makeItem(id: 3, pid: 300)
        ]

        await openSwitcher(store)
        store.selectedID = 3

        store.commitSelection()

        try expectEqual(activator.activatedItems.map(\.id), [3])
        try expect(!store.isVisible)

        let baselineSnapshots = catalog.visibleSnapshotCount
        store.requestCycle(forward: true)
        await runPendingMainTasks()

        try expect(store.isVisible)
        try expectEqual(
            store.items.map(\.id),
            [3, 1, 2],
            "a rapid reopen should not replay the pre-commit cached order and leave the newly selected app at the tail"
        )
        try expectEqual(catalog.visibleSnapshotCount, baselineSnapshots)
    }

    @MainActor static func requestCycle_reusesInFlightWarmupSnapshot() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        catalog.visibleSnapshotDelayNanoseconds = 150_000_000

        store.scheduleOpenItemsCacheWarmup(context: "test warmup")
        // Wait until the warmup's off-main snapshot has actually begun (it bumps
        // the count, then sleeps 150 ms inside snapshotVisibleOnly). A fixed yield
        // count raced the detached task's start under suite load; poll instead so
        // the in-flight task is live when requestCycle below tries to reuse it.
        for _ in 0 ..< 100 where catalog.visibleSnapshotCount == 0 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        try expectEqual(catalog.visibleSnapshotCount, 1)

        store.requestCycle(forward: true)
        for _ in 0 ..< 6 {
            await Task.yield()
        }

        try expectEqual(catalog.visibleSnapshotCount, 1,
                        "requestCycle should await the in-flight warmup snapshot instead of starting a second visible snapshot")

        for _ in 0 ..< 40 {
            if store.isVisible { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if !store.isVisible {
            try? await Task.sleep(nanoseconds: 130_000_000)
        }
        await runPendingMainTasks()

        try expect(store.isVisible)
        try expectEqual(store.items.map(\.id), [1, 2])
    }

    @MainActor static func requestCycle_slowSnapshotDoesNotPaySecondPanelDelay() async throws {
        let (store, catalog, _, _) = makeStore(initialPanelShowDelayNanoseconds: 120_000_000)
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        catalog.visibleSnapshotDelayNanoseconds = 180_000_000

        store.requestCycle(forward: true)

        try? await Task.sleep(nanoseconds: 220_000_000)
        await runPendingMainTasks()

        try expect(
            store.isVisible,
            "panel should appear as soon as the slow snapshot is ready instead of paying the full panel delay again"
        )
        try expectEqual(store.items.map(\.id), [1, 2])
    }

    @MainActor static func requestCycle_usesStaleCachedItemsImmediatelyThenRefreshes() async throws {
        let (store, catalog, _, _) = makeStore(cachedOpenItemsMaxAge: -1)
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        await seedOpenItemsCache(store)

        let baselineSnapshots = catalog.visibleSnapshotCount
        catalog.visibleItems = [
            makeItem(id: 3, isFrontmostApp: true),
            makeItem(id: 4)
        ]

        store.requestCycle(forward: true)

        try expect(store.isVisible, "stale cached request should show cached items immediately while the refresh runs")
        try expectEqual(catalog.visibleSnapshotCount, baselineSnapshots)
        try expectEqual(store.items.map(\.id), [1, 2])

        await runPendingMainTasks()

        try expect(store.isVisible)
        try expectEqual(store.items.map(\.id), [3, 4])
        try expectEqual(catalog.visibleSnapshotCount, baselineSnapshots + 1)
    }

    @MainActor static func requestCycle_staleRefreshDoesNotShowVisiblePanelAgain() async throws {
        let (store, catalog, _, _) = makeStore(cachedOpenItemsMaxAge: -1)
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        await seedOpenItemsCache(store)

        var onShowCalls = 0
        store.onShow = { onShowCalls += 1 }
        catalog.visibleItems = [
            makeItem(id: 3, isFrontmostApp: true),
            makeItem(id: 4)
        ]

        store.requestCycle(forward: true)

        try expect(store.isVisible)
        try expectEqual(onShowCalls, 1)
        try expectEqual(store.items.map(\.id), [1, 2])

        await runPendingMainTasks()

        try expect(store.isVisible)
        try expectEqual(store.items.map(\.id), [3, 4])
        try expectEqual(
            onShowCalls,
            1,
            "stale-cache refresh should update the visible panel without ordering it front again"
        )
    }

    @MainActor static func requestCycle_staleCachedOpenHealsCacheEvenAfterImmediateCommit() async throws {
        let (store, catalog, activator, _) = makeStore(
            cachedOpenItemsMaxAge: -1,
            initialPanelShowDelayNanoseconds: 120_000_000
        )
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200)
        ]
        await seedOpenItemsCache(store)

        catalog.visibleItems = [
            makeItem(id: 3, pid: 300, isFrontmostApp: true),
            makeItem(id: 4, pid: 400)
        ]
        catalog.visibleSnapshotDelayNanoseconds = 100_000_000

        store.requestCycle(forward: true)

        try expect(store.isSwitching)
        try expect(!store.isVisible, "stale cached request should stay hidden long enough for quick release to commit directly")

        store.commitSelection()
        await runPendingMainTasks()

        try expect(!store.isVisible)
        try expectEqual(activator.activatedItems.map(\.id), [2])

        catalog.visibleSnapshotDelayNanoseconds = 0
        try? await Task.sleep(nanoseconds: 150_000_000)
        await runPendingMainTasks()

        store.requestCycle(forward: true)

        try expect(!store.isVisible)
        try? await Task.sleep(nanoseconds: 130_000_000)
        await runPendingMainTasks()

        try expect(store.isVisible)
        try expectEqual(store.items.map(\.id), [3, 4])
    }

    @MainActor static func requestCycle_staleSameAppQuickReleaseWaitsForFreshSnapshot() async throws {
        let (store, catalog, activator, _) = makeStore(
            cachedOpenItemsMaxAge: -1,
            initialPanelShowDelayNanoseconds: 120_000_000
        )
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, title: "A", isFrontmostApp: true),
            makeItem(id: 2, pid: 100, title: "B", isFrontmostApp: true)
        ]
        await seedOpenItemsCache(store)

        catalog.visibleItems = [
            makeItem(id: 3, pid: 100, title: "A", isFrontmostApp: true),
            makeItem(id: 4, pid: 100, title: "B", isFrontmostApp: true)
        ]
        catalog.visibleSnapshotDelayNanoseconds = 100_000_000

        store.requestCycle(forward: true)
        store.commitSelection()
        await runPendingMainTasks()

        try expect(
            activator.activatedItems.isEmpty,
            "same-app stale quick release must not activate the old cached window before the fresh snapshot returns"
        )

        catalog.visibleSnapshotDelayNanoseconds = 0
        try? await Task.sleep(nanoseconds: 150_000_000)
        await runPendingMainTasks()

        try expect(!store.isVisible)
        try expectEqual(activator.activatedItems.map(\.id), [4])
    }

    // MARK: ordering

    @MainActor static func ordering_frontmost() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, appName: "Other"),
            makeItem(id: 2, appName: "Front", isFrontmostApp: true),
            makeItem(id: 3, appName: "Another")
        ]
        await openSwitcher(store)
        try expectEqual(store.items.first?.id, 2)
    }

    @MainActor static func ordering_recent() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, pid: 1, isFrontmostApp: true),
            makeItem(id: 2, pid: 2),
            makeItem(id: 3, pid: 3)
        ]
        await openSwitcher(store)
        store.selectedID = 3
        store.commitSelection()
        await runPendingMainTasks()
        try expectEqual(activator.activatedItems.last?.id, 3)

        catalog.visibleItems = [
            makeItem(id: 1, pid: 1, isFrontmostApp: true),
            makeItem(id: 2, pid: 2),
            makeItem(id: 3, pid: 3)
        ]
        // Activating window 3 above fires a real app activation; that marks the
        // cached open list for resnapshot so the next open re-reads the world
        // (and applies the updated MRU order) instead of replaying the cache.
        store.handleAppActivation(pid: 3)
        await openSwitcher(store)
        try expectEqual(store.items.map(\.id), [1, 3, 2])
    }

    @MainActor static func ordering_alphabeticalKeepsFrontmostFirst() async throws {
        let settings = SwitchBladeSettings.shared
        let oldSortOrder = settings.sortOrder
        settings.sortOrder = .alphabetical
        defer { settings.sortOrder = oldSortOrder }

        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, appName: "Front", title: "Zulu", isFrontmostApp: true),
            makeItem(id: 2, appName: "Beta", title: "Charlie"),
            makeItem(id: 3, appName: "Alpha", title: "Bravo"),
            makeItem(id: 4, appName: "Gamma", title: "Alpha")
        ]

        await openSwitcher(store)

        try expectEqual(store.items.map(\.id), [1, 4, 3, 2])
    }

    @MainActor static func ordering_appGroupedKeepsFrontmostFirst() async throws {
        let settings = SwitchBladeSettings.shared
        let oldSortOrder = settings.sortOrder
        settings.sortOrder = .appGrouped
        defer { settings.sortOrder = oldSortOrder }

        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, appName: "Front", title: "Zulu", isFrontmostApp: true),
            makeItem(id: 2, appName: "Beta", title: "Window B"),
            makeItem(id: 3, appName: "Alpha", title: "Window C"),
            makeItem(id: 4, appName: "Alpha", title: "Window A")
        ]

        await openSwitcher(store)

        try expectEqual(store.items.map(\.id), [1, 4, 3, 2])
    }

    // MARK: preview modes

    @MainActor static func previewMode_iconsOnlySkipsCaptures() async throws {
        let settings = SwitchBladeSettings.shared
        let oldPreviewMode = settings.previewMode
        settings.previewMode = .iconsOnly
        defer { settings.previewMode = oldPreviewMode }

        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]

        await openSwitcher(store)
        await runPendingMainTasks()

        try expect(store.isVisible)
        try expectEqual(catalog.captureCallCount, 0)
        try expect(store.items.allSatisfy { $0.preview == nil })
    }

    @MainActor static func previewCapture_skipsUncapturableItems() async throws {
        let settings = SwitchBladeSettings.shared
        let oldPreviewMode = settings.previewMode
        settings.previewMode = .livePreviews
        defer { settings.previewMode = oldPreviewMode }

        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2, canCapturePreview: false),
            makeItem(id: 3)
        ]

        await openSwitcher(store)
        await runPendingMainTasks()

        let capturedIDs = catalog.captureWindowIDCalls.flatMap { $0 }
        try expectEqual(Set(capturedIDs), Set<CGWindowID>([1, 3]))
        try expect(!capturedIDs.contains(2), "uncapturable item should not be requested")
    }

    @MainActor static func previewCapture_limitsDeferredBatch() async throws {
        let settings = SwitchBladeSettings.shared
        let oldPreviewMode = settings.previewMode
        settings.previewMode = .livePreviews
        defer { settings.previewMode = oldPreviewMode }

        let (store, catalog, _, _) = makeStore(deferredPreviewCaptureBudget: 3)
        let image = NSImage(size: CGSize(width: 8, height: 8))
        catalog.visibleItems = (1...16).map { index in
            makeItem(id: CGWindowID(index), title: "Window \(index)", isFrontmostApp: index == 1)
        }
        catalog.previewsToReturn = Dictionary(uniqueKeysWithValues: (1...10).map { (CGWindowID($0), image) })

        await openSwitcher(store)
        await runPendingMainTasks(20)

        try expectEqual(catalog.captureWindowIDCalls.count, 3)
        try expectEqual(catalog.captureWindowIDCalls[0], [CGWindowID(2), CGWindowID(1)])
        try expectEqual(catalog.captureWindowIDCalls[1], [3, 4, 5, 6, 7, 8, 9, 10].map(CGWindowID.init))
        try expectEqual(catalog.captureWindowIDCalls[2], [CGWindowID(11), CGWindowID(12), CGWindowID(13)])
    }

    @MainActor static func previewCapture_skipsCachedDeferredItems() async throws {
        let settings = SwitchBladeSettings.shared
        let oldPreviewMode = settings.previewMode
        settings.previewMode = .livePreviews
        defer { settings.previewMode = oldPreviewMode }

        let image = NSImage(size: CGSize(width: 8, height: 8))
        let (store, catalog, _, _) = makeStore(deferredPreviewCaptureBudget: 4)
        catalog.visibleItems = [
            makeItem(id: 11, title: "Window 11", isFrontmostApp: true),
            makeItem(id: 12, title: "Window 12")
        ]
        catalog.previewsToReturn = [11: image, 12: image]

        await store.warmPreviewCache(context: "test")
        catalog.previewsToReturn = Dictionary(uniqueKeysWithValues: (1...10).map { (CGWindowID($0), image) })
        catalog.visibleItems = (1...14).map { index in
            makeItem(id: CGWindowID(index), title: "Window \(index)", isFrontmostApp: index == 1)
        }
        // The window list changed after the warm pass; an app activation marks the
        // cache for resnapshot so the open re-reads fresh instead of replaying the
        // warmed [11, 12] list — while still reusing their warmed previews.
        store.handleAppActivation(pid: 1)
        await openSwitcher(store)
        await runPendingMainTasks(20)

        try expectEqual(catalog.captureWindowIDCalls.count, 4)
        try expectEqual(catalog.captureWindowIDCalls[0], [CGWindowID(11), CGWindowID(12)])
        try expectEqual(catalog.captureWindowIDCalls[1], [CGWindowID(2), CGWindowID(1)])
        try expectEqual(catalog.captureWindowIDCalls[2], [3, 4, 5, 6, 7, 8, 9, 10].map(CGWindowID.init))
        try expectEqual(catalog.captureWindowIDCalls[3], [CGWindowID(13), CGWindowID(14)])
    }

    @MainActor static func warmPreviewCache_populatesFirstOpen() async throws {
        let settings = SwitchBladeSettings.shared
        let oldPreviewMode = settings.previewMode
        settings.previewMode = .livePreviews
        defer { settings.previewMode = oldPreviewMode }

        let preview = NSImage(size: CGSize(width: 10, height: 10))
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        catalog.previewsToReturn = [1: preview]

        await store.warmPreviewCache(context: "test")
        // The warm pass populated the cache, so requestCycle takes the cached
        // path synchronously: items hydrate from the cache (no new capture yet —
        // the preview pass is deferred until the panel shows).
        store.requestCycle(forward: true)

        try expectEqual(catalog.captureCallCount, 1)
        try expect(store.items.first(where: { $0.id == 1 })?.preview === preview)
    }

    @MainActor static func warmPreviewCache_primesHiddenDisplayItems() async throws {
        let settings = SwitchBladeSettings.shared
        let oldPreviewMode = settings.previewMode
        settings.previewMode = .livePreviews
        defer { settings.previewMode = oldPreviewMode }

        let preview = NSImage(size: CGSize(width: 10, height: 10))
        let (store, catalog, _, _) = makeStore()
        var preparedCounts: [Int] = []
        store.onPreparePanel = { preparedCounts.append($0) }
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        catalog.previewsToReturn = [1: preview]

        await store.warmPreviewCache(context: "test")

        try expect(!store.isVisible)
        try expect(!store.isSwitching)
        try expectEqual(store.items.map(\.id), [1, 2])
        try expectEqual(store.selectedID, 2)
        try expect(store.items.first(where: { $0.id == 1 })?.preview === preview)
        try expectEqual(preparedCounts, [2, 2])
    }

    @MainActor static func warmPreviewCache_limitsBackgroundCaptureBatch() async throws {
        let settings = SwitchBladeSettings.shared
        let oldPreviewMode = settings.previewMode
        settings.previewMode = .livePreviews
        defer { settings.previewMode = oldPreviewMode }

        let image = NSImage(size: CGSize(width: 8, height: 8))
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = (1...8).map { index in
            makeItem(id: CGWindowID(index), title: "Window \(index)", isFrontmostApp: index == 1)
        }
        catalog.previewsToReturn = Dictionary(uniqueKeysWithValues: (1...8).map { (CGWindowID($0), image) })

        await store.warmPreviewCache(context: "test")

        try expectEqual(catalog.captureCallCount, 1)
        try expectEqual(catalog.lastCaptureWindowIDs, [1, 2, 3, 4].map(CGWindowID.init))
    }

    @MainActor static func warmPreviewCache_iconsOnlySkipsCaptures() async throws {
        let settings = SwitchBladeSettings.shared
        let oldPreviewMode = settings.previewMode
        settings.previewMode = .iconsOnly
        defer { settings.previewMode = oldPreviewMode }

        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]

        await store.warmPreviewCache(context: "test")

        try expectEqual(catalog.captureCallCount, 0)
    }

    // MARK: handleKeyDown

    @MainActor static func handleKeyDown_notVisible() async throws {
        let (store, _, _, _) = makeStore()
        try expect(store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_Tab)) == false)
    }

    @MainActor static func handleKeyDown_tabForward() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)
        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_Tab))
        try expect(handled)
        try expectEqual(store.selectedID, 3)
    }

    @MainActor static func handleKeyDown_shiftTabBackward() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)
        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_Tab, modifiers: .shift))
        try expect(handled)
        try expectEqual(store.selectedID, 1)
    }

    @MainActor static func handleKeyDown_arrows() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)
        _ = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_RightArrow))
        try expectEqual(store.selectedID, 3)
        _ = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_LeftArrow))
        try expectEqual(store.selectedID, 2)
        _ = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_DownArrow))
        try expectEqual(store.selectedID, 3)
        _ = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_UpArrow))
        try expectEqual(store.selectedID, 2)
    }

    @MainActor static func handleKeyDown_returnCommits() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)
        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_Return))
        try expect(handled)
        try expect(!store.isVisible)
        await runPendingMainTasks()
        try expectEqual(activator.activatedItems.last?.id, 2)
    }

    @MainActor static func handleKeyDown_escape() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        await openSwitcher(store)
        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_Escape))
        try expect(handled)
        try expect(!store.isVisible)
        try expect(activator.activatedItems.isEmpty)
    }

    @MainActor static func handleKeyDown_unknown() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        await openSwitcher(store)
        try expect(store.handleKeyDown(makeKeyDownEvent(keyCode: 0)) == false)
    }

    @MainActor static func handleKeyDown_home() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)              // selected = 2
        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_Home))
        try expect(handled)
        try expectEqual(store.selectedID, store.items.first?.id)
    }

    @MainActor static func handleKeyDown_end() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)              // selected = 2
        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_End))
        try expect(handled)
        try expectEqual(store.selectedID, store.items.last?.id)
    }

    @MainActor static func handleKeyDown_cmdQ() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2, pid: 200)
        ]
        await openSwitcher(store)
        store.selectedID = 2

        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_ANSI_Q, modifiers: .command))
        try expect(handled)
        try expectEqual(activator.quitItems.map(\.id), [2])
        try expect(!store.isVisible)
    }

    @MainActor static func handleKeyDown_cmdH() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2, pid: 200)
        ]
        await openSwitcher(store)
        store.selectedID = 2

        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_ANSI_H, modifiers: .command))
        try expect(handled)
        try expectEqual(activator.hiddenItems.map(\.id), [2])
        try expect(!store.isVisible)
    }

    @MainActor static func handleKeyDown_cmdComma() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        var openSettingsCalls = 0
        store.onOpenSettings = { openSettingsCalls += 1 }
        await openSwitcher(store)

        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_ANSI_Comma, modifiers: .command))

        try expect(handled)
        try expect(!store.isVisible)
        try expectEqual(openSettingsCalls, 1)
    }

    @MainActor static func handleKeyDown_optionArrowSnaps() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)

        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_LeftArrow, modifiers: .option))

        try expect(handled)
        try expect(!store.isVisible)
        await runPendingMainTasks()
        try expectEqual(activator.snapCalls, [.init(id: 2, edge: .left)])
    }

    @MainActor static func quit_removesAllPidWindows() async throws {
        let (store, catalog, activator, _) = makeStore()
        // Two windows of the same app (pid 200) + one of another app (pid 300)
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200),
            makeItem(id: 3, pid: 200, title: "Other window"),
            makeItem(id: 4, pid: 300)
        ]
        await openSwitcher(store)
        store.selectedID = 2

        _ = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_ANSI_Q, modifiers: .command))

        // Both pid-200 windows are gone; other apps remain in the list state.
        try expectEqual(activator.quitItems.map(\.pid), [200])
        try expect(!store.items.contains(where: { $0.pid == 200 }))
    }

    @MainActor static func switchToPreviousApplication_activatesPreviousPid() async throws {
        let settings = SwitchBladeSettings.shared
        let oldValue = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = oldValue }

        let (store, _, activator, _) = makeStore(initialFrontmostAppPID: 101, switchBladePID: 999)
        store.handleAppActivation(pid: 202)

        store.switchToPreviousApplication()
        await runPendingMainTasks()

        try expectEqual(activator.activatedApplicationPIDs, [101])
    }

    @MainActor static func switchToPreviousApplication_disabledSetting() async throws {
        let settings = SwitchBladeSettings.shared
        let oldValue = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = false
        defer { settings.doubleModifierSwitchEnabled = oldValue }

        let (store, _, activator, _) = makeStore(initialFrontmostAppPID: 101, switchBladePID: 999)
        store.handleAppActivation(pid: 202)

        store.switchToPreviousApplication()

        try expect(activator.activatedApplicationPIDs.isEmpty)
    }

    @MainActor static func switchToPreviousApplication_infersPreviousPid() async throws {
        let settings = SwitchBladeSettings.shared
        let oldValue = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = oldValue }

        let catalog = MockWindowCatalog()
        catalog.visibleItems = [
            makeItem(id: 1, pid: 202, isFrontmostApp: true),
            makeItem(id: 2, pid: 101)
        ]
        let (store, _, activator, _) = makeStore(catalog: catalog, initialFrontmostAppPID: 202, switchBladePID: 999)

        store.switchToPreviousApplication()
        await runPendingMainTasks()

        try expectEqual(activator.activatedApplicationPIDs, [101])
        try expectEqual(catalog.visibleSnapshotCount, 1)
    }

    @MainActor static func switchToPreviousApplication_sameAppWindowsBounceInsteadOfPickingOtherApp() async throws {
        let settings = SwitchBladeSettings.shared
        let oldValue = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = oldValue }

        let userDefaults = makeIsolatedUserDefaults()
        let catalog = MockWindowCatalog()
        let activator = MockWindowActivator()
        let permissions = MockPermissionService()
        let mruTracker = MRUTracker(userDefaults: userDefaults)
        // Seed MRU so that position 1 is a same-app sibling (A before Other App).
        mruTracker.rememberSelection(2, in: [
            makeItem(id: 2, pid: 100, title: "B", isFrontmostApp: true),
            makeItem(id: 1, pid: 100, title: "A"),
            makeItem(id: 3, pid: 200, title: "Other App")
        ])
        let store = SwitcherStore(
            catalog: catalog,
            activator: activator,
            permissionService: permissions,
            userDefaults: userDefaults,
            mruTracker: mruTracker,
            initialFrontmostAppPID: 100,
            switchBladePID: 999
        )

        // Snapshot: B frontmost. orderedForDisplay → [B, A, Other]. Position 1 = A (same pid).
        catalog.visibleItems = [
            makeItem(id: 2, pid: 100, title: "B", isFrontmostApp: true),
            makeItem(id: 1, pid: 100, title: "A"),
            makeItem(id: 3, pid: 200, title: "Other App")
        ]

        store.switchToPreviousApplication()
        await runPendingMainTasks()

        // Position 1 = A (same pid 100) → window-level switch to A.
        try expectEqual(activator.activatedItems.map(\.id), [1])
        try expect(activator.activatedApplicationPIDs.isEmpty)

        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, title: "A", isFrontmostApp: true),
            makeItem(id: 2, pid: 100, title: "B"),
            makeItem(id: 3, pid: 200, title: "Other App")
        ]

        store.switchToPreviousApplication()
        await runPendingMainTasks()

        // Position 1 = B (same pid 100) → window-level bounce back to B.
        try expectEqual(activator.activatedItems.map(\.id), [1, 2])
        try expect(activator.activatedApplicationPIDs.isEmpty)

        catalog.visibleItems = [
            makeItem(id: 2, pid: 100, title: "B", isFrontmostApp: true),
            makeItem(id: 1, pid: 100, title: "A"),
            makeItem(id: 3, pid: 200, title: "Other App")
        ]

        store.switchToPreviousApplication()
        await runPendingMainTasks()

        // Third press: still bouncing within the same-app pair (A↔B cycling is sticky).
        // Cross-app fallback is not triggered while a same-app sibling sits at position 1.
        try expectEqual(activator.activatedItems.map(\.id), [1, 2, 1])
        try expect(activator.activatedApplicationPIDs.isEmpty)
    }

    @MainActor static func switchToPreviousApplication_usesSnapshotCurrentPidWhenTrackedPidIsStale() async throws {
        let settings = SwitchBladeSettings.shared
        let oldValue = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = oldValue }

        let userDefaults = makeIsolatedUserDefaults()
        let catalog = MockWindowCatalog()
        let activator = MockWindowActivator()
        let permissions = MockPermissionService()
        let mruTracker = MRUTracker(userDefaults: userDefaults)
        // Seed MRU so position 1 is a same-app sibling (A before Other App).
        mruTracker.rememberSelection(2, in: [
            makeItem(id: 2, pid: 100, title: "B", isFrontmostApp: true),
            makeItem(id: 1, pid: 100, title: "A"),
            makeItem(id: 3, pid: 200, title: "Other App")
        ])
        // initialFrontmostAppPID is 200 (stale — store hasn't received the activation
        // notification yet). The snapshot already shows B (pid=100) as frontmost.
        let store = SwitcherStore(
            catalog: catalog,
            activator: activator,
            permissionService: permissions,
            userDefaults: userDefaults,
            mruTracker: mruTracker,
            initialFrontmostAppPID: 200,
            switchBladePID: 999
        )

        // Snapshot pid 100 must win over stale currentAppPID 200.
        // orderedForDisplay → [B, A, Other]. effectiveCurrentPID = 100 (from snapshot).
        // Position 1 = A (pid 100) → window-level switch to A.
        catalog.visibleItems = [
            makeItem(id: 2, pid: 100, title: "B", isFrontmostApp: true),
            makeItem(id: 1, pid: 100, title: "A"),
            makeItem(id: 3, pid: 200, title: "Other App")
        ]

        store.switchToPreviousApplication()
        await runPendingMainTasks()

        try expectEqual(activator.activatedItems.map(\.id), [1])
        try expect(activator.activatedApplicationPIDs.isEmpty)
    }

    @MainActor static func switchToPreviousApplication_bouncesBetweenTwoApps() async throws {
        let settings = SwitchBladeSettings.shared
        let oldValue = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = oldValue }

        let (store, _, activator, _) = makeStore(initialFrontmostAppPID: 101, switchBladePID: 999)
        store.handleAppActivation(pid: 202)

        store.switchToPreviousApplication()
        await runPendingMainTasks()
        store.handleAppActivation(pid: 101)
        store.switchToPreviousApplication()
        await runPendingMainTasks()

        try expectEqual(activator.activatedApplicationPIDs, [101, 202])
    }

    /// Two gestures before the first's off-main snapshot resolves: the second
    /// is dropped, so the PID the first mutates can't drive a second unintended
    /// switch. Exactly one activation results.
    @MainActor static func switchToPreviousApplication_concurrentGestureDropped() async throws {
        let settings = SwitchBladeSettings.shared
        let oldValue = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = oldValue }

        let (store, _, activator, _) = makeStore(initialFrontmostAppPID: 101, switchBladePID: 999)
        store.handleAppActivation(pid: 202)

        store.switchToPreviousApplication()
        store.switchToPreviousApplication()
        await runPendingMainTasks()

        try expectEqual(activator.activatedApplicationPIDs, [101])
    }

    @MainActor static func switchToPreviousApplication_singleWindowCachedPreviousPidSkipsSnapshot() async throws {
        let settings = SwitchBladeSettings.shared
        let oldValue = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = oldValue }

        let catalog = MockWindowCatalog()
        catalog.visibleItems = [
            makeItem(id: 1, pid: 101, isFrontmostApp: true),
            makeItem(id: 2, pid: 202)
        ]
        let (store, _, activator, _) = makeStore(
            catalog: catalog,
            activationWarmupWindow: -1,
            initialFrontmostAppPID: 101,
            switchBladePID: 999
        )
        await seedOpenItemsCache(store)
        let baselineSnapshots = catalog.visibleSnapshotCount
        catalog.visibleSnapshotDelayNanoseconds = 200_000_000
        store.handleAppActivation(pid: 202)

        store.switchToPreviousApplication()

        try expectEqual(activator.activatedApplicationPIDs, [101])
        try expectEqual(catalog.visibleSnapshotCount, baselineSnapshots)
    }

    @MainActor static func handleModifierMouseSwitch_visibleCommitsSelection() async throws {
        let settings = SwitchBladeSettings.shared
        let oldValue = settings.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = oldValue }

        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200),
            makeItem(id: 3, pid: 300)
        ]
        await openSwitcher(store)

        try expect(store.isVisible)
        try expectEqual(store.selectedID, 2)

        store.handleModifierMouseSwitch()
        await runPendingMainTasks()

        try expectEqual(activator.activatedItems.map(\.id), [2])
        try expect(!store.isVisible)
    }

    @MainActor static func snap_itemRoutesToActivator() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)

        store.snap(makeItem(id: 3), to: .bottom)

        try expect(!store.isVisible)
        await runPendingMainTasks()
        try expectEqual(activator.snapCalls, [.init(id: 3, edge: .bottom)])
    }

    // MARK: commit / cancel

    @MainActor static func commit_activates() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        await openSwitcher(store)
        store.selectedID = 1

        store.commitSelection()
        try expect(!store.isVisible)
        await runPendingMainTasks()
        try expectEqual(activator.activatedItems.map(\.id), [1])
    }

    @MainActor static func commit_dispatchesActivationSynchronously() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        await openSwitcher(store)
        store.selectedID = 1

        store.commitSelection()

        try expect(!store.isVisible)
        try expectEqual(
            activator.activatedItems.map(\.id),
            [1],
            "selection activation should not wait for a deferred MainActor sleep"
        )
    }

    @MainActor static func commit_noSelection() async throws {
        let (store, _, activator, _) = makeStore()
        store.commitSelection()
        await runPendingMainTasks()
        try expect(!store.isVisible)
        try expect(activator.activatedItems.isEmpty)
    }

    @MainActor static func cancel_hides() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        await openSwitcher(store)
        var onHideCalls = 0
        store.onHide = { onHideCalls += 1 }

        store.cancel()
        await runPendingMainTasks()

        try expect(!store.isVisible)
        try expectEqual(onHideCalls, 1)
        try expect(activator.activatedItems.isEmpty)
    }

    // MARK: close

    @MainActor static func close_callsActivator() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)
        let toClose = store.items.first(where: { $0.id == 2 })!

        store.close(toClose)

        try expectEqual(activator.closedItems.map(\.id), [2])
        try expectEqual(store.items.map(\.id), [1, 3])
    }

    @MainActor static func close_lastItem() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [makeItem(id: 1, isFrontmostApp: true)]
        await openSwitcher(store)
        store.close(store.items[0])
        try expect(store.items.isEmpty)
        try expect(!store.isVisible)
    }

    @MainActor static func close_picksNeighbor() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)
        store.selectedID = 2
        let toClose = store.items.first(where: { $0.id == 2 })!
        store.close(toClose)
        try expectNotNil(store.selectedID)
        try expect(store.selectedID != 2)
    }

    // MARK: hover

    @MainActor static func hover_ignoredInitially() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        await openSwitcher(store)
        let originalSelection = store.selectedID

        // hoverEnabled is false until scheduleHoverEnable fires after 200 ms.
        store.hover(store.items[1])
        try expectEqual(store.selectedID, originalSelection)
    }

    // MARK: choose

    @MainActor static func choose_commits() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        await openSwitcher(store)
        let target = store.items.first(where: { $0.id == 3 })!

        store.choose(target)
        try expect(!store.isVisible)
        await runPendingMainTasks()
        try expectEqual(activator.activatedItems.last?.id, 3)
    }
}
