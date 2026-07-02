import CoreGraphics
import Foundation
@testable import SwitchBladeCore

enum MRUTrackerTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("MRU/orderedForDisplay_putsFrontmostFirst", frontmostFirst),
        ("MRU/orderedForDisplay_thenRecentWindowIDs", recentSecond),
        ("MRU/orderedForDisplay_persistedBundleIDs_seedNewSession", persistedSeed),
        ("MRU/orderedForDisplay_persistedBundleIDs_includeFrontmostSiblings", persistedSeedIncludesFrontmostSiblings),
        ("MRU/orderedForDisplay_keepsSameAppMRURank", sameAppKeepsMRURank),
        ("MRU/orderedForDisplay_switchMovesSelectedWindowOnly", switchMovesSelectedWindowOnly),
        ("MRU/orderedForDisplay_sameAppWindows_keepIndependentRanks", sameAppWindowsNotBundled),
        ("MRU/orderedForDisplay_sameAppSwitchMovesSelectedWindowOnly", sameAppSwitchMovesSelectedWindowOnly),
        ("MRU/orderedForDisplay_transientMissingWindow_keepsRankWhenItReturns", transientMissingWindowKeepsRank),
        ("MRU/orderedForDisplay_recreatedWindow_keepsRankBySignature", recreatedWindowKeepsRankBySignature),
        ("MRU/orderedForDisplay_singleWindowTitleChange_keepsRankByAppIdentity", singleWindowTitleChangeKeepsRankByAppIdentity),
        ("MRU/orderedForDisplay_sameAppSiblingSeen_recreatedOtherWindowKeepsRankByIdentity", sameAppSiblingSeenRecreatedOtherWindowKeepsRankByIdentity),
        ("MRU/orderedForDisplay_multiWindowTitleChange_doesNotGuessByAppIdentity", multiWindowTitleChangeDoesNotGuessByAppIdentity),
        ("MRU/pruneToLive_singleWindowIdentityRank_survivesIDAndTitleChange", pruneSingleWindowIdentityRankSurvivesIDAndTitleChange),
        ("MRU/trackSystemActivation_doesNotMovePidWindowsToFront", systemActivation),
        ("MRU/trackSystemActivation_doesNotPruneFromStaleStoreSnapshot", systemActivationDoesNotPrune),
        ("MRU/trackSystemActivation_singleWindowAppGetsIdentityRank", systemActivationSingleWindowAppGetsIdentityRank),
        ("MRU/trackSystemActivation_multiWindowAppIsNotGuessed", systemActivationMultiWindowAppIsNotGuessed),
        ("MRU/orderedForDisplay_sameAppConcreteRankBeatsOtherAppIdentityRank", sameAppConcreteRankBeatsOtherAppIdentityRank),
        ("MRU/orderedForDisplay_frontmostAppDoesNotGroupAllSiblingRanks", frontmostAppDoesNotGroupAllSiblingRanks),
        ("MRU/orderedForDisplay_nonAdjacentFrontmostSiblingsDoNotBeatIdentityRank", nonAdjacentFrontmostSiblingsDoNotBeatIdentityRank),
        ("MRU/pruneToLive_dropsDeadIDs", pruneDeadIDs),
        ("MRU/pruneToLive_emptyList_clearsAllRankData", pruneToLiveEmpty),
        ("MRU/pruneToLive_alsoDropsStaleSignatures", pruneDropsSignatures),
        ("MRU/rememberSelection_capsAtMaxBundles", capsBundles),
        ("MRU/recentRanks_cappedAtMaxRanks", recentRanksCapped),
        ("MRU/dropRank_removesOnlySpecifiedWindowKeepsOthers", dropRankSpecificOnly),
        ("MRU/dropAllRanksForApp_clearsRanksAndBundle", dropAllRanksForApp),
        ("MRU/rememberSelection_nilBundleID_writesRanksSkipsBundleList", rememberSelectionNilBundle),
        ("MRU/rememberSelection_preservesRanksForWindowsMissingFromStaleLiveItems", rememberSelectionPreservesMissing),
        ("MRU/rememberSelection_staleListMissingWindow_doesNotDemoteItsRank", staleListMissingWindowDoesNotDemoteRank),
        ("MRU/rememberSelection_movesOnlySelectedRank", rememberSelectionMovesOnlySelectedRank),
        ("MRU/orderedForDisplay_emptySnapshot_returnsEmpty", orderedForDisplayEmpty),
        ("MRU/orderedForDisplay_noFrontmostFlag_usesFirstInSnapshot", orderedForDisplayNoFrontmost)
    ]

    @MainActor static func frontmostFirst() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let snapshot = [
            makeItem(id: 1, appName: "A"),
            makeItem(id: 2, appName: "B", isFrontmostApp: true),
            makeItem(id: 3, appName: "C")
        ]
        let ordered = tracker.orderedForDisplay(from: snapshot)
        try expectEqual(ordered.first?.id, 2)
    }

    @MainActor static func recentSecond() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let snapshot = [
            makeItem(id: 1, pid: 1, isFrontmostApp: true, bundleIdentifier: "a"),
            makeItem(id: 2, pid: 2, bundleIdentifier: "b"),
            makeItem(id: 3, pid: 3, bundleIdentifier: "c")
        ]
        // User has just picked window 3 in a prior cycle.
        tracker.rememberSelection(3, in: snapshot)

        let ordered = tracker.orderedForDisplay(from: snapshot)
        // Frontmost (1), then recent (3), then the rest (2).
        try expectEqual(ordered.map(\.id), [1, 3, 2])
    }

    @MainActor static func persistedSeedIncludesFrontmostSiblings() throws {
        let ud = makeIsolatedUserDefaults()
        ud.set(["bundle.a", "bundle.b"], forKey: "sb_recentBundleIDs")

        let tracker = MRUTracker(userDefaults: ud)
        let snapshot = [
            makeItem(id: 1, pid: 1, isFrontmostApp: true, bundleIdentifier: "bundle.a"),
            makeItem(id: 2, pid: 2, bundleIdentifier: "bundle.c"),
            makeItem(id: 3, pid: 1, bundleIdentifier: "bundle.a"),
            makeItem(id: 4, pid: 3, bundleIdentifier: "bundle.b")
        ]
        let ordered = tracker.orderedForDisplay(from: snapshot)
        try expectEqual(ordered.map(\.id), [1, 3, 4, 2])
    }

    @MainActor static func persistedSeed() throws {
        let ud = makeIsolatedUserDefaults()
        ud.set(["bundle.b"], forKey: "sb_recentBundleIDs")

        let tracker = MRUTracker(userDefaults: ud)
        let snapshot = [
            makeItem(id: 1, pid: 1, isFrontmostApp: true, bundleIdentifier: "bundle.a"),
            makeItem(id: 2, pid: 2, bundleIdentifier: "bundle.c"),
            makeItem(id: 3, pid: 3, bundleIdentifier: "bundle.b")
        ]
        let ordered = tracker.orderedForDisplay(from: snapshot)
        try expectEqual(ordered.map(\.id), [1, 3, 2])
    }

    // Same-app windows keep the explicit MRU rank instead of being rearranged
    // as an app-level group.
    @MainActor static func sameAppKeepsMRURank() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        // Two terminal windows (same pid), one browser (different pid).
        // Snapshot z-order: browser (frontmost), terminal-B (z-front), terminal-A.
        let snapshot = [
            makeItem(id: 1, pid: 200, isFrontmostApp: true),  // browser
            makeItem(id: 3, pid: 100),                          // terminal-B (z-front)
            makeItem(id: 2, pid: 100),                          // terminal-A
        ]
        // Switcher history has terminal-A (id=2) as the more recently *selected* window.
        tracker.rememberSelection(2, in: snapshot)

        let ordered = tracker.orderedForDisplay(from: snapshot)
        // Expected: browser first, then terminal-A before terminal-B. Clicking
        // the app should not move terminal-B ahead unless that exact window is
        // the current frontmost item.
        try expectEqual(ordered.map(\.id), [1, 2, 3])
    }

    // Switching to a window moves only that selected window. Other windows keep
    // the rank they already had in the MRU chain.
    @MainActor static func switchMovesSelectedWindowOnly() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        // User was in browser (pid=200), switches to terminal-A (pid=100) via
        // the switcher.
        let snapshotFromBrowser = [
            makeItem(id: 3, pid: 200, isFrontmostApp: true),  // browser (leaving)
            makeItem(id: 1, pid: 100),                          // terminal-A
            makeItem(id: 2, pid: 100),                          // terminal-B
        ]
        // Build the existing chain through real selections (terminal-B, then
        // browser), so the chain reads [3, 2] before the switch.
        tracker.rememberSelection(2, in: snapshotFromBrowser)
        tracker.rememberSelection(3, in: snapshotFromBrowser)
        tracker.rememberSelection(1, in: snapshotFromBrowser)

        // After switch: terminal-A is frontmost.
        let snapshotAfter = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),  // terminal-A
            makeItem(id: 2, pid: 100),                          // terminal-B
            makeItem(id: 3, pid: 200),                          // browser
        ]
        let ordered = tracker.orderedForDisplay(from: snapshotAfter)
        // Terminal-A is current, then browser and terminal-B keep their existing rank.
        try expectEqual(ordered.map(\.id), [1, 3, 2])
    }

    // Regression test: same-app windows must keep their independent ranks in
    // the MRU chain — NOT get bundled adjacent. User complaint: "yhtäkkiä
    // saman apin ikkunat siirtyvätkin peräkkäin switcherin listalla vaikka
    // ovat aiemmin olleet ketjussa eri kohdissa".
    @MainActor static func sameAppWindowsNotBundled() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        // Interleaved usage history: browser-B, editor, browser-A, slack,
        // terminal — selected oldest-first so the chain interleaves the two
        // browser windows with other apps.
        let snapshot = [
            makeItem(id: 10, pid: 100, isFrontmostApp: true),  // terminal (frontmost)
            makeItem(id: 40, pid: 400),                          // slack
            makeItem(id: 20, pid: 200),                          // browser-A
            makeItem(id: 30, pid: 300),                          // editor
            makeItem(id: 21, pid: 200),                          // browser-B
        ]
        tracker.rememberSelection(21, in: snapshot)
        tracker.rememberSelection(30, in: snapshot)
        tracker.rememberSelection(20, in: snapshot)
        tracker.rememberSelection(40, in: snapshot)
        tracker.rememberSelection(10, in: snapshot)
        // recentWindowIDs = [10, 40, 20, 30, 21] — browser-A and browser-B are
        // at positions 3 and 5, NOT adjacent.

        // Display snapshot arrives in a different z-order; the chain, not the
        // snapshot, must drive the result.
        let displaySnapshot = [
            makeItem(id: 10, pid: 100, isFrontmostApp: true),
            makeItem(id: 21, pid: 200),
            makeItem(id: 20, pid: 200),
            makeItem(id: 30, pid: 300),
            makeItem(id: 40, pid: 400),
        ]
        let ordered = tracker.orderedForDisplay(from: displaySnapshot)
        // Expected: interleaved chain order preserved. browser-A and browser-B
        // are NOT bundled adjacent — each keeps its independent MRU rank.
        try expectEqual(ordered.map(\.id), [10, 40, 20, 30, 21])
    }

    // Same-app switching follows the same per-window rule: the selected window
    // moves to the front, unrelated windows keep their rank.
    @MainActor static func sameAppSwitchMovesSelectedWindowOnly() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        // App X (pid=100) has two windows A (id=1) and B (id=2). App Y (pid=200)
        // has one window C (id=3). User is cycling between A and B.
        let snapshot = [
            makeItem(id: 2, pid: 100, isFrontmostApp: true),  // X-B (frontmost after switch)
            makeItem(id: 1, pid: 100),                          // X-A (sibling)
            makeItem(id: 3, pid: 200),                          // Y-C
        ]
        // Simulate: user was on X-A, opened switcher, selected X-B.
        tracker.rememberSelection(1, in: snapshot)  // establish some prior state
        tracker.rememberSelection(2, in: snapshot)  // user committed X-B

        let ordered = tracker.orderedForDisplay(from: snapshot)
        // X-B at 0 (frontmost), then X-A and Y-C keep the rank from the last selection.
        try expectEqual(ordered.map(\.id), [2, 1, 3])
    }

    // Regression guard: a window can be absent from one CGWindowList snapshot
    // during warmup / Space churn and then reappear. That must not erase its
    // per-window rank and push it to the fallback tail.
    @MainActor static func transientMissingWindowKeepsRank() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let fullSnapshot = [
            makeItem(id: 1, pid: 100, title: "Terminal A", isFrontmostApp: true),
            makeItem(id: 2, pid: 100, title: "Terminal B"),
            makeItem(id: 3, pid: 200, title: "Browser")
        ]
        tracker.rememberSelection(2, in: fullSnapshot)

        let transientSnapshot = [
            makeItem(id: 1, pid: 100, title: "Terminal A", isFrontmostApp: true),
            makeItem(id: 3, pid: 200, title: "Browser")
        ]
        _ = tracker.orderedForDisplay(from: transientSnapshot)

        let orderedAfterReturn = tracker.orderedForDisplay(from: fullSnapshot)
        try expectEqual(orderedAfterReturn.map(\.id), [1, 2, 3])
    }

    @MainActor static func recreatedWindowKeepsRankBySignature() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let initialSnapshot = [
            makeItem(id: 1, pid: 100, appName: "Terminal", title: "Terminal A", isFrontmostApp: true),
            makeItem(id: 2, pid: 100, appName: "Terminal", title: "Terminal B"),
            makeItem(id: 3, pid: 200, appName: "Browser", title: "Browser")
        ]
        tracker.rememberSelection(2, in: initialSnapshot)

        let recreatedSnapshot = [
            makeItem(id: 1, pid: 100, appName: "Terminal", title: "Terminal A", isFrontmostApp: true),
            makeItem(id: 3, pid: 200, appName: "Browser", title: "Browser"),
            makeItem(id: 20, pid: 100, appName: "Terminal", title: "Terminal B")
        ]

        let ordered = tracker.orderedForDisplay(from: recreatedSnapshot)
        try expectEqual(ordered.map(\.id), [1, 20, 3])
    }

    @MainActor static func singleWindowTitleChangeKeepsRankByAppIdentity() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let initialSnapshot = [
            makeItem(id: 1, pid: 100, appName: "Editor", title: "Project", isFrontmostApp: true),
            makeItem(id: 2, pid: 200, appName: "Ghostty", title: "shell"),
            makeItem(id: 3, pid: 300, appName: "Browser", title: "Docs")
        ]
        tracker.rememberSelection(2, in: initialSnapshot)

        let recreatedSnapshot = [
            makeItem(id: 1, pid: 100, appName: "Editor", title: "Project", isFrontmostApp: true),
            makeItem(id: 3, pid: 300, appName: "Browser", title: "Docs"),
            makeItem(id: 20, pid: 200, appName: "Ghostty", title: "vim")
        ]

        let ordered = tracker.orderedForDisplay(from: recreatedSnapshot)
        try expectEqual(ordered.map(\.id), [1, 20, 3])
    }

    // Regression guard: when one window of a multi-window app is already
    // frontmost/seen, the other window should still recover its old rank by
    // app identity if it is the only remaining unseen candidate from that app.
    @MainActor static func sameAppSiblingSeenRecreatedOtherWindowKeepsRankByIdentity() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let initialSnapshot = [
            makeItem(id: 1, pid: 200, appName: "Ghostty", title: "shell A", isFrontmostApp: true),
            makeItem(id: 2, pid: 200, appName: "Ghostty", title: "shell B"),
            makeItem(id: 3, pid: 300, appName: "Browser", title: "Docs")
        ]
        tracker.rememberSelection(2, in: initialSnapshot)

        let recreatedSnapshot = [
            makeItem(id: 1, pid: 200, appName: "Ghostty", title: "shell A", isFrontmostApp: true),
            makeItem(id: 3, pid: 300, appName: "Browser", title: "Docs"),
            makeItem(id: 20, pid: 200, appName: "Ghostty", title: "vim")
        ]

        let ordered = tracker.orderedForDisplay(from: recreatedSnapshot)
        try expectEqual(ordered.map(\.id), [1, 20, 3])
    }

    @MainActor static func multiWindowTitleChangeDoesNotGuessByAppIdentity() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let initialSnapshot = [
            makeItem(id: 1, pid: 100, appName: "Editor", title: "Project", isFrontmostApp: true),
            makeItem(id: 2, pid: 200, appName: "Ghostty", title: "shell A"),
            makeItem(id: 3, pid: 300, appName: "Browser", title: "Docs"),
            makeItem(id: 4, pid: 200, appName: "Ghostty", title: "shell B")
        ]
        tracker.rememberSelection(2, in: initialSnapshot)

        let recreatedSnapshot = [
            makeItem(id: 1, pid: 100, appName: "Editor", title: "Project", isFrontmostApp: true),
            makeItem(id: 3, pid: 300, appName: "Browser", title: "Docs"),
            makeItem(id: 20, pid: 200, appName: "Ghostty", title: "vim A"),
            makeItem(id: 40, pid: 200, appName: "Ghostty", title: "vim B")
        ]

        let ordered = tracker.orderedForDisplay(from: recreatedSnapshot)
        try expectEqual(ordered.map(\.id), [1, 3, 20, 40])
    }

    // Regression guard: if a single-window app changes both CGWindowID and
    // title, a later prune must not slide the next app into that old rank and
    // leave the recreated single window at the snapshot tail.
    @MainActor static func pruneSingleWindowIdentityRankSurvivesIDAndTitleChange() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let initialSnapshot = [
            makeItem(
                id: 1,
                pid: 100,
                appName: "Editor",
                title: "Project",
                isFrontmostApp: true,
                bundleIdentifier: "com.example.editor"
            ),
            makeItem(
                id: 2,
                pid: 200,
                appName: "Microsoft Word",
                title: "Doc A",
                bundleIdentifier: "com.microsoft.Word"
            ),
            makeItem(
                id: 3,
                pid: 300,
                appName: "Browser",
                title: "Docs",
                bundleIdentifier: "com.example.browser"
            ),
            makeItem(
                id: 4,
                pid: 400,
                appName: "Mail",
                title: "Inbox",
                bundleIdentifier: "com.example.mail"
            )
        ]
        tracker.rememberSelection(2, in: initialSnapshot)

        let liveAfterWordChurn = [
            makeItem(
                id: 1,
                pid: 100,
                appName: "Editor",
                title: "Project",
                isFrontmostApp: true,
                bundleIdentifier: "com.example.editor"
            ),
            makeItem(
                id: 3,
                pid: 300,
                appName: "Browser",
                title: "Docs",
                bundleIdentifier: "com.example.browser"
            ),
            makeItem(
                id: 4,
                pid: 400,
                appName: "Mail",
                title: "Inbox",
                bundleIdentifier: "com.example.mail"
            ),
            makeItem(
                id: 20,
                pid: 200,
                appName: "Microsoft Word",
                title: "Doc B",
                bundleIdentifier: "com.microsoft.Word"
            )
        ]

        tracker.pruneToLive(liveAfterWordChurn)

        let ordered = tracker.orderedForDisplay(from: liveAfterWordChurn)
        try expectEqual(ordered.map(\.id), [1, 20, 3, 4])
    }

    // Regression guard: app-level activation must not move every known window
    // of that pid. The notification does not tell us which window was touched.
    @MainActor static func systemActivation() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let items = [
            makeItem(id: 10, pid: 100),
            makeItem(id: 20, pid: 200),
            makeItem(id: 21, pid: 200),
            makeItem(id: 30, pid: 300)
        ]
        // Pre-populate recents in arbitrary order.
        tracker.rememberSelection(30, in: items)
        tracker.rememberSelection(10, in: items)
        tracker.rememberSelection(20, in: items)

        let before = tracker.recentWindowIDs

        // System reports pid 100 just activated. That should prune stale IDs
        // only, not reshuffle windows unrelated to a concrete selection.
        tracker.trackSystemActivation(100, in: items)
        try expectEqual(tracker.recentWindowIDs, before)
    }

    @MainActor static func systemActivationDoesNotPrune() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let items = [
            makeItem(id: 10, pid: 100),
            makeItem(id: 20, pid: 200),
            makeItem(id: 30, pid: 300)
        ]
        tracker.rememberSelection(30, in: items)
        tracker.rememberSelection(20, in: items)

        let before = tracker.recentWindowIDs
        tracker.trackSystemActivation(300, in: [
            makeItem(id: 10, pid: 100),
            makeItem(id: 30, pid: 300)
        ])

        try expectEqual(tracker.recentWindowIDs, before)
    }

    @MainActor static func systemActivationSingleWindowAppGetsIdentityRank() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let initialSnapshot = [
            makeItem(id: 1, pid: 100, appName: "Editor", isFrontmostApp: true, bundleIdentifier: "com.example.editor"),
            makeItem(id: 2, pid: 200, appName: "Browser", bundleIdentifier: "com.example.browser")
        ]
        tracker.rememberSelection(2, in: initialSnapshot)

        tracker.trackSystemActivation(300, in: [], bundleIdentifier: "com.openai.codex")

        let nextSnapshot = [
            makeItem(id: 1, pid: 100, appName: "Editor", isFrontmostApp: true, bundleIdentifier: "com.example.editor"),
            makeItem(id: 2, pid: 200, appName: "Browser", bundleIdentifier: "com.example.browser"),
            makeItem(id: 30, pid: 300, appName: "Codex", title: "Codex", bundleIdentifier: "com.openai.codex")
        ]
        let ordered = tracker.orderedForDisplay(from: nextSnapshot)

        try expectEqual(ordered.map(\.id), [1, 30, 2])
    }

    @MainActor static func systemActivationMultiWindowAppIsNotGuessed() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let initialSnapshot = [
            makeItem(id: 1, pid: 100, appName: "Editor", isFrontmostApp: true, bundleIdentifier: "com.example.editor"),
            makeItem(id: 2, pid: 200, appName: "Browser", bundleIdentifier: "com.example.browser")
        ]
        tracker.rememberSelection(2, in: initialSnapshot)

        tracker.trackSystemActivation(300, in: [], bundleIdentifier: "com.example.multi")

        let nextSnapshot = [
            makeItem(id: 1, pid: 100, appName: "Editor", isFrontmostApp: true, bundleIdentifier: "com.example.editor"),
            makeItem(id: 2, pid: 200, appName: "Browser", bundleIdentifier: "com.example.browser"),
            makeItem(id: 30, pid: 300, appName: "Multi", title: "A", bundleIdentifier: "com.example.multi"),
            makeItem(id: 31, pid: 300, appName: "Multi", title: "B", bundleIdentifier: "com.example.multi")
        ]
        let ordered = tracker.orderedForDisplay(from: nextSnapshot)

        try expectEqual(ordered.map(\.id), [1, 2, 30, 31])
    }

    @MainActor static func sameAppConcreteRankBeatsOtherAppIdentityRank() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let initialSnapshot = [
            makeItem(id: 10, pid: 100, appName: "Outlook", title: "Mail", isFrontmostApp: true, bundleIdentifier: "com.microsoft.Outlook"),
            makeItem(id: 11, pid: 100, appName: "Outlook", title: "Message", bundleIdentifier: "com.microsoft.Outlook"),
            makeItem(id: 20, pid: 200, appName: "Browser", title: "Docs", bundleIdentifier: "com.example.browser")
        ]
        // Both Outlook windows carry concrete ranks from real selections; the
        // chain reads [10, 11] before the browser activation.
        tracker.rememberSelection(11, in: initialSnapshot)
        tracker.rememberSelection(10, in: initialSnapshot)

        tracker.trackSystemActivation(200, in: [], bundleIdentifier: "com.example.browser")

        let nextSnapshot = [
            makeItem(id: 11, pid: 100, appName: "Outlook", title: "Message", isFrontmostApp: true, bundleIdentifier: "com.microsoft.Outlook"),
            makeItem(id: 20, pid: 200, appName: "Browser", title: "Docs", bundleIdentifier: "com.example.browser"),
            makeItem(id: 10, pid: 100, appName: "Outlook", title: "Mail", bundleIdentifier: "com.microsoft.Outlook")
        ]
        let ordered = tracker.orderedForDisplay(from: nextSnapshot)

        try expectEqual(ordered.map(\.id), [11, 10, 20])
    }

    @MainActor static func frontmostAppDoesNotGroupAllSiblingRanks() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let initialSnapshot = [
            makeItem(id: 100, pid: 10, appName: "Codex", title: "Codex", isFrontmostApp: true, bundleIdentifier: "com.openai.codex"),
            makeItem(id: 200, pid: 20, appName: "Finder", title: "Downloads", bundleIdentifier: "com.apple.finder"),
            makeItem(id: 300, pid: 30, appName: "Claude", title: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop"),
            makeItem(id: 201, pid: 20, appName: "Finder", title: "Desktop", bundleIdentifier: "com.apple.finder"),
            makeItem(id: 400, pid: 40, appName: "Safari", title: "Docs", bundleIdentifier: "com.apple.Safari"),
            makeItem(id: 202, pid: 20, appName: "Finder", title: "Documents", bundleIdentifier: "com.apple.finder")
        ]
        // Interleaved usage history oldest-first so every window holds its own
        // concrete rank: chain reads [200, 100, 300, 201, 400, 202].
        tracker.rememberSelection(202, in: initialSnapshot)
        tracker.rememberSelection(400, in: initialSnapshot)
        tracker.rememberSelection(201, in: initialSnapshot)
        tracker.rememberSelection(300, in: initialSnapshot)
        tracker.rememberSelection(100, in: initialSnapshot)
        tracker.rememberSelection(200, in: initialSnapshot)

        tracker.trackSystemActivation(20, in: [], bundleIdentifier: "com.apple.finder")

        let nextSnapshot = [
            makeItem(id: 200, pid: 20, appName: "Finder", title: "Downloads", isFrontmostApp: true, bundleIdentifier: "com.apple.finder"),
            makeItem(id: 100, pid: 10, appName: "Codex", title: "Codex", bundleIdentifier: "com.openai.codex"),
            makeItem(id: 300, pid: 30, appName: "Claude", title: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop"),
            makeItem(id: 201, pid: 20, appName: "Finder", title: "Desktop", isFrontmostApp: true, bundleIdentifier: "com.apple.finder"),
            makeItem(id: 400, pid: 40, appName: "Safari", title: "Docs", bundleIdentifier: "com.apple.Safari"),
            makeItem(id: 202, pid: 20, appName: "Finder", title: "Documents", isFrontmostApp: true, bundleIdentifier: "com.apple.finder")
        ]
        let ordered = tracker.orderedForDisplay(from: nextSnapshot)

        try expectEqual(ordered.map(\.id), [200, 100, 300, 201, 400, 202])
    }

    @MainActor static func nonAdjacentFrontmostSiblingsDoNotBeatIdentityRank() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let initialSnapshot = [
            makeItem(id: 201, pid: 20, appName: "Finder", title: "Desktop", isFrontmostApp: true, bundleIdentifier: "com.apple.finder"),
            makeItem(id: 202, pid: 20, appName: "Finder", title: "Documents", isFrontmostApp: true, bundleIdentifier: "com.apple.finder"),
            makeItem(id: 300, pid: 30, appName: "Claude", title: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop"),
            makeItem(id: 200, pid: 20, appName: "Finder", title: "Downloads", isFrontmostApp: true, bundleIdentifier: "com.apple.finder")
        ]
        tracker.rememberSelection(201, in: initialSnapshot)

        tracker.trackSystemActivation(10, in: [], bundleIdentifier: "com.openai.codex")

        let nextSnapshot = [
            makeItem(id: 200, pid: 20, appName: "Finder", title: "Downloads", isFrontmostApp: true, bundleIdentifier: "com.apple.finder"),
            makeItem(id: 100, pid: 10, appName: "Codex", title: "Codex", bundleIdentifier: "com.openai.codex"),
            makeItem(id: 201, pid: 20, appName: "Finder", title: "Desktop", isFrontmostApp: true, bundleIdentifier: "com.apple.finder"),
            makeItem(id: 202, pid: 20, appName: "Finder", title: "Documents", isFrontmostApp: true, bundleIdentifier: "com.apple.finder"),
            makeItem(id: 300, pid: 30, appName: "Claude", title: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop")
        ]
        let ordered = tracker.orderedForDisplay(from: nextSnapshot)

        try expectEqual(ordered.map(\.id), [200, 100, 201, 202, 300])
    }

    @MainActor static func pruneDeadIDs() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let snapshot = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        tracker.rememberSelection(2, in: snapshot)
        tracker.rememberSelection(3, in: snapshot)
        tracker.rememberSelection(1, in: snapshot)

        // Only item 1 is still alive.
        tracker.pruneToLive([makeItem(id: 1, isFrontmostApp: true)])
        try expectEqual(tracker.recentWindowIDs, [1])
    }

    @MainActor static func pruneToLiveEmpty() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let snapshot = [makeItem(id: 1, isFrontmostApp: true), makeItem(id: 2)]
        tracker.rememberSelection(2, in: snapshot)
        tracker.pruneToLive([])
        try expectEqual(tracker.recentWindowIDs, [])
        try expectEqual(tracker.recentWindowSignatures, [])
    }

    @MainActor static func pruneDropsSignatures() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let snapshot = [
            makeItem(id: 1, appName: "Terminal", title: "A", isFrontmostApp: true),
            makeItem(id: 2, appName: "Terminal", title: "B")
        ]
        tracker.rememberSelection(1, in: snapshot)
        tracker.rememberSelection(2, in: snapshot)
        try expect(!tracker.recentWindowSignatures.isEmpty)
        tracker.pruneToLive([makeItem(id: 1, appName: "Terminal", title: "A", isFrontmostApp: true)])
        // Signature for "Terminal B" must be gone; only "Terminal A" survives.
        try expectEqual(tracker.recentWindowSignatures.count, 1)
    }

    @MainActor static func rememberSelectionNilBundle() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let snapshot = [
            makeItem(id: 1, appName: "NoBundle", isFrontmostApp: true, bundleIdentifier: nil),
            makeItem(id: 2, appName: "NoBundle", bundleIdentifier: nil)
        ]
        tracker.rememberSelection(2, in: snapshot)
        // Window and signature ranks are written.
        try expectEqual(tracker.recentWindowIDs.first, 2)
        try expect(!tracker.recentWindowSignatures.isEmpty)
        // Bundle list must stay empty — no bundleIdentifier to persist.
        try expectEqual(tracker.recentBundleIDs, [])
    }

    // Regression guard: when the switcher commits while showing a stale cached
    // list, `rememberSelection` must NOT erase ranks for windows that exist in
    // reality but happen to be absent from this snapshot. Only `pruneToLive`
    // (called on explicit close/quit) may drop ranks. Without this guarantee,
    // any window missing from the cached list at commit time falls to the
    // snapshot-fallback tail on the next switcher open.
    @MainActor static func rememberSelectionPreservesMissing() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let fullSnapshot = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200),
            makeItem(id: 3, pid: 300),
            makeItem(id: 4, pid: 400)
        ]
        // Establish per-window MRU through real selections: chain reads [3, 4].
        tracker.rememberSelection(4, in: fullSnapshot)
        tracker.rememberSelection(3, in: fullSnapshot)

        // Stale cached list shown to the user — window 4 is missing (warmup
        // captured a moment when CGWindowList didn't enumerate it). Committing
        // from it must not demote 4's rank.
        let staleLiveItems = [
            makeItem(id: 3, pid: 300, isFrontmostApp: true),
            makeItem(id: 1, pid: 100),
            makeItem(id: 2, pid: 200)
        ]
        tracker.rememberSelection(2, in: staleLiveItems)

        // A brand-new window 5 appears alongside the rediscovered 4. The
        // genuinely-new window falls behind every ranked window; 4 keeps its
        // chain position right after 3.
        let nextSnapshot = [
            makeItem(id: 2, pid: 200, isFrontmostApp: true),
            makeItem(id: 5, pid: 500),
            makeItem(id: 1, pid: 100),
            makeItem(id: 3, pid: 300),
            makeItem(id: 4, pid: 400)
        ]
        let ordered = tracker.orderedForDisplay(from: nextSnapshot)
        try expectEqual(ordered.map(\.id), [2, 3, 4, 5, 1])
    }

    // THE tail-drift regression: committing from a partial list (minimized
    // merge pending, other Space filtered, stale cache) must not demote the
    // ranks of windows that happen to be absent. The old full-rewrite
    // semantics pushed every absent rank behind all live windows.
    @MainActor static func staleListMissingWindowDoesNotDemoteRank() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let fullSnapshot = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200),
            makeItem(id: 3, pid: 300),
            makeItem(id: 4, pid: 400)
        ]
        // Usage history oldest-first: chain reads [4, 3, 2, 1].
        tracker.rememberSelection(1, in: fullSnapshot)
        tracker.rememberSelection(2, in: fullSnapshot)
        tracker.rememberSelection(3, in: fullSnapshot)
        tracker.rememberSelection(4, in: fullSnapshot)

        // Quick-release commit from a partial list: window 2 is absent.
        let partialLiveItems = [
            makeItem(id: 4, pid: 400, isFrontmostApp: true),
            makeItem(id: 3, pid: 300),
            makeItem(id: 1, pid: 100)
        ]
        tracker.rememberSelection(3, in: partialLiveItems)

        let nextSnapshot = [
            makeItem(id: 3, pid: 300, isFrontmostApp: true),
            makeItem(id: 1, pid: 100),
            makeItem(id: 2, pid: 200),
            makeItem(id: 4, pid: 400)
        ]
        let ordered = tracker.orderedForDisplay(from: nextSnapshot)
        // Old full-rewrite semantics produced [3, 4, 1, 2] — 2 demoted to the tail.
        try expectEqual(ordered.map(\.id), [3, 4, 2, 1])
    }

    // Selecting a window moves exactly one rank; every other rank keeps both
    // its relative order and its position.
    @MainActor static func rememberSelectionMovesOnlySelectedRank() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let fullSnapshot = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200),
            makeItem(id: 3, pid: 300),
            makeItem(id: 4, pid: 400)
        ]
        tracker.rememberSelection(1, in: fullSnapshot)
        tracker.rememberSelection(2, in: fullSnapshot)
        tracker.rememberSelection(3, in: fullSnapshot)
        tracker.rememberSelection(4, in: fullSnapshot)  // chain [4, 3, 2, 1]

        tracker.rememberSelection(1, in: fullSnapshot)  // re-select the tail window

        try expectEqual(tracker.recentWindowIDs, [1, 4, 3, 2])
    }

    @MainActor static func orderedForDisplayEmpty() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let result = tracker.orderedForDisplay(from: [])
        try expectEqual(result, [])
    }

    @MainActor static func orderedForDisplayNoFrontmost() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let snapshot = [
            makeItem(id: 1, appName: "A"),
            makeItem(id: 2, appName: "B"),
            makeItem(id: 3, appName: "C")
        ]
        let ordered = tracker.orderedForDisplay(from: snapshot)
        // No isFrontmostApp flag → snapshot[0] used as frontmost.
        try expectEqual(ordered.first?.id, 1)
    }

    // Regression guard for the "random tail" bug: closing one window from the
    // switcher used to call `pruneToLive(items)` against the displayed list,
    // which would also drop ranks for any live window absent from that view
    // (e.g. minimized windows that hadn't merged in yet). Those windows then
    // fell to the snapshot-fallback tail on the next open. Targeted dropRank
    // touches only the actually-closed window's rank.
    @MainActor static func dropRankSpecificOnly() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let snapshot = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200),
            makeItem(id: 3, pid: 300),
            makeItem(id: 4, pid: 400)
        ]
        tracker.rememberSelection(3, in: snapshot)
        // recentRanks now: [3, 1, 2, 4]

        // User closes window 2 from the switcher. Only its rank should go.
        tracker.dropRank(forID: 2)

        let liveItemsAfterClose = snapshot.filter { $0.id != 2 }
        let ordered = tracker.orderedForDisplay(from: liveItemsAfterClose)
        // 1 frontmost, then 3 (rank-leading), then 4 (preserved tail rank).
        try expectEqual(ordered.map(\.id), [1, 3, 4])
    }

    @MainActor static func dropAllRanksForApp() throws {
        let ud = makeIsolatedUserDefaults()
        let tracker = MRUTracker(userDefaults: ud)
        let snapshot = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true, bundleIdentifier: "com.example.editor"),
            makeItem(id: 2, pid: 200, bundleIdentifier: "com.example.terminal"),
            makeItem(id: 3, pid: 200, bundleIdentifier: "com.example.terminal"),
            makeItem(id: 4, pid: 300, bundleIdentifier: "com.example.browser")
        ]
        tracker.rememberSelection(2, in: snapshot)
        try expect(tracker.recentBundleIDs.contains("com.example.terminal"))

        // User quits Terminal entirely. Both windows + bundle entry should clear.
        tracker.dropAllRanks(
            forAppIdentity: "com.example.terminal",
            bundleIdentifier: "com.example.terminal"
        )

        let live = snapshot.filter { $0.bundleIdentifier != "com.example.terminal" }
        let ordered = tracker.orderedForDisplay(from: live)
        try expectEqual(ordered.map(\.id), [1, 4])
        try expect(!tracker.recentBundleIDs.contains("com.example.terminal"))
    }

    @MainActor static func capsBundles() throws {
        let ud = makeIsolatedUserDefaults()
        let tracker = MRUTracker(userDefaults: ud, maxBundles: 3)
        let items = (0..<10).map { i in
            makeItem(id: CGWindowID(i + 1), pid: pid_t(100 + i), bundleIdentifier: "bundle.\(i)")
        }
        // Remember all 10 in sequence.
        for item in items {
            tracker.rememberSelection(item.id, in: items)
        }
        try expectEqual(tracker.recentBundleIDs.count, 3)
        try expectEqual(tracker.recentBundleIDs.first, "bundle.9")
    }

    /// Each selection has only its own window live, so prior ranks are preserved
    /// rather than rebuilt — without the cap, ranks would grow unbounded over a
    /// long session and slow every `orderedForDisplay` scan.
    @MainActor static func recentRanksCapped() throws {
        let ud = makeIsolatedUserDefaults()
        let tracker = MRUTracker(userDefaults: ud, maxRanks: 3)
        for i in 1...8 {
            let item = makeItem(id: CGWindowID(i), pid: pid_t(100 + i), bundleIdentifier: "bundle.\(i)")
            tracker.rememberSelection(item.id, in: [item])
        }
        try expectEqual(tracker.recentWindowIDs, [8, 7, 6])
    }
}
