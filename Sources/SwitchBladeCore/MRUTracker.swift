import AppKit
import CoreGraphics
import Foundation

/// MRU bookkeeping in two layers:
/// 1. In-memory `recentWindowIDs` — fine-grained, per-window, lost on relaunch.
/// 2. Persisted `recentBundleIDs` — coarse, per-app, survives relaunch.
///
/// `orderedForDisplay(from:)` produces the canonical switcher ordering used
/// every cold open: frontmost app first, then in-memory recents, then the
/// persisted bundle order, then anything left in the snapshot.
@MainActor
final class MRUTracker {
    private(set) var recentWindowIDs: [CGWindowID] = []
    private(set) var recentBundleIDs: [String]

    private let maxBundles: Int
    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "sb_recentBundleIDs",
        maxBundles: Int = 30
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.maxBundles = maxBundles
        self.recentBundleIDs = (userDefaults.array(forKey: storageKey) as? [String]) ?? []
    }

    /// Builds the display order for a snapshot.
    func orderedForDisplay(from snapshot: [WindowItem]) -> [WindowItem] {
        guard !snapshot.isEmpty else { return [] }

        // isFrontmostApp comes from NSWorkspace at snapshot time and is more
        // accurate than snapshot.first (CGWindowList z-order lags briefly after
        // an activation).
        let currentFrontmost = snapshot.first(where: { $0.isFrontmostApp }) ?? snapshot[0]

        let liveIDs = Set(snapshot.map(\.id))
        recentWindowIDs.removeAll { !liveIDs.contains($0) }

        let itemsByID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        var ordered: [WindowItem] = [currentFrontmost]
        var seen: Set<WindowItem.ID> = [currentFrontmost.id]

        for id in recentWindowIDs where seen.insert(id).inserted {
            if let item = itemsByID[id] { ordered.append(item) }
        }

        // Persisted bundle order seeds the first cycle after a fresh launch
        // when `recentWindowIDs` hasn't been populated yet.
        if !recentBundleIDs.isEmpty {
            let snapshotByBundle = Dictionary(grouping: snapshot, by: { $0.bundleIdentifier })
            for bundleID in recentBundleIDs {
                guard let group = snapshotByBundle[bundleID] else { continue }
                for item in group where seen.insert(item.id).inserted {
                    ordered.append(item)
                }
            }
        }

        for item in snapshot where seen.insert(item.id).inserted {
            ordered.append(item)
        }
        return ordered
    }

    /// Records the user's choice from `liveItems` and writes the bundle list
    /// back to UserDefaults.
    func rememberSelection(_ id: CGWindowID, in liveItems: [WindowItem]) {
        recentWindowIDs = [id] + liveItems.map(\.id).filter { $0 != id }

        guard let item = liveItems.first(where: { $0.id == id }),
              let bundleID = item.bundleIdentifier,
              !bundleID.isEmpty else { return }

        recentBundleIDs.removeAll { $0 == bundleID }
        recentBundleIDs.insert(bundleID, at: 0)
        if recentBundleIDs.count > maxBundles {
            recentBundleIDs.removeLast(recentBundleIDs.count - maxBundles)
        }
        userDefaults.set(recentBundleIDs, forKey: storageKey)
    }

    /// Mirrors a system-initiated activation (NSWorkspace notification) into
    /// our MRU: every window of the activated app moves to the front.
    func trackSystemActivation(pid: pid_t, in liveItems: [WindowItem]) {
        let activated = recentWindowIDs.filter { id in
            liveItems.first(where: { $0.id == id })?.pid == pid
        }
        let rest = recentWindowIDs.filter { id in
            liveItems.first(where: { $0.id == id })?.pid != pid
        }
        recentWindowIDs = activated + rest
    }

    /// Removes IDs that no longer correspond to live items.
    func pruneToLive(_ liveItems: [WindowItem]) {
        let liveIDs = Set(liveItems.map(\.id))
        recentWindowIDs.removeAll { !liveIDs.contains($0) }
    }
}
