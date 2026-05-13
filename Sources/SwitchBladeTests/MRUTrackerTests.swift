import CoreGraphics
import Foundation
@testable import SwitchBladeCore

enum MRUTrackerTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("MRU/orderedForDisplay_putsFrontmostFirst", frontmostFirst),
        ("MRU/orderedForDisplay_thenRecentWindowIDs", recentSecond),
        ("MRU/orderedForDisplay_persistedBundleIDs_seedNewSession", persistedSeed),
        ("MRU/trackSystemActivation_movesPidWindowsToFront", systemActivation),
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
            makeItem(id: 1, isFrontmostApp: true, bundleIdentifier: "a"),
            makeItem(id: 2, bundleIdentifier: "b"),
            makeItem(id: 3, bundleIdentifier: "c")
        ]
        // User has just picked window 3 in a prior cycle.
        tracker.rememberSelection(3, in: snapshot)

        let ordered = tracker.orderedForDisplay(from: snapshot)
        // Frontmost (1), then recent (3), then the rest (2).
        try expectEqual(ordered.map(\.id), [1, 3, 2])
    }

    @MainActor static func persistedSeed() throws {
        let ud = makeIsolatedUserDefaults()
        ud.set(["bundle.b"], forKey: "sb_recentBundleIDs")

        let tracker = MRUTracker(userDefaults: ud)
        let snapshot = [
            makeItem(id: 1, isFrontmostApp: true, bundleIdentifier: "bundle.a"),
            makeItem(id: 2, bundleIdentifier: "bundle.c"),
            makeItem(id: 3, bundleIdentifier: "bundle.b")
        ]
        let ordered = tracker.orderedForDisplay(from: snapshot)
        try expectEqual(ordered.map(\.id), [1, 3, 2])
    }

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

        // System reports pid 100 just activated → its windows move to the front.
        tracker.trackSystemActivation(pid: 100, in: items)
        try expectEqual(tracker.recentWindowIDs.first, 10)
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
