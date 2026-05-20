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
        ("MRU/trackSystemActivation_doesNotMovePidWindowsToFront", systemActivation),
        ("MRU/trackSystemActivation_doesNotPruneFromStaleStoreSnapshot", systemActivationDoesNotPrune),
        ("MRU/pruneToLive_dropsDeadIDs", pruneDeadIDs),
        ("MRU/rememberSelection_capsAtMaxBundles", capsBundles)
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
        // Snapshot in interleaved order: terminal (frontmost), slack, browser-A,
        // editor, browser-B. After rememberSelection(10) the MRU chain reflects
        // this interleaving (rememberSelection seeds from liveItems order).
        let snapshot = [
            makeItem(id: 10, pid: 100, isFrontmostApp: true),  // terminal (frontmost)
            makeItem(id: 40, pid: 400),                          // slack
            makeItem(id: 20, pid: 200),                          // browser-A
            makeItem(id: 30, pid: 300),                          // editor
            makeItem(id: 21, pid: 200),                          // browser-B
        ]
        tracker.rememberSelection(10, in: snapshot)
        // recentWindowIDs = [10, 40, 20, 30, 21] — browser-A and browser-B are
        // at positions 3 and 5, NOT adjacent.

        let ordered = tracker.orderedForDisplay(from: snapshot)
        // Expected: same interleaved order preserved. browser-A and browser-B
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

    @MainActor static func pruneDeadIDs() throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let snapshot = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        tracker.rememberSelection(2, in: snapshot)
        tracker.rememberSelection(3, in: snapshot)

        // Only item 1 is still alive.
        tracker.pruneToLive([makeItem(id: 1, isFrontmostApp: true)])
        try expectEqual(tracker.recentWindowIDs, [1])
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
}
