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
    // PID of the app the user was leaving when they last committed a switcher
    // selection. Used by orderedForDisplay to detect same-app cycling: when
    // lastFromPID matches the current frontmost PID the user was bouncing
    // within the same app, and the most-recent sibling surfaces at position 1.
    // Direct-click activations (trackSystemActivation) intentionally do NOT
    // update this — only explicit switcher choices count.
    private(set) var lastFromPID: pid_t?

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
    ///
    /// Each window keeps its independent rank in `recentWindowIDs`. Same-app
    /// windows are NOT bundled adjacent — interleaving with other apps is
    /// preserved, matching the user's mental model of the MRU chain.
    ///
    /// Two adjustments preserve the "right window of an app" intent without
    /// bundling:
    /// - Frontmost app's other windows skip the cross-app pass and are appended
    ///   last — UNLESS the previous switcher selection was also from the same
    ///   app (same-app cycling). In that case the single most-recent sibling is
    ///   allowed through at position 1 so the user can bounce back immediately.
    /// - For each non-frontmost PID, the snapshot z-front window is promoted
    ///   ahead of its same-app peers on first encounter. `trackSystemActivation`
    ///   only knows the PID, not which specific window was clicked — z-order
    ///   reveals that, so a directly-clicked window wins over an older
    ///   switcher-selected sibling on the very next cycle.
    func orderedForDisplay(from snapshot: [WindowItem]) -> [WindowItem] {
        guard !snapshot.isEmpty else { return [] }

        // isFrontmostApp comes from NSWorkspace at snapshot time and is more
        // accurate than snapshot.first (CGWindowList z-order lags briefly after
        // an activation).
        let currentFrontmost = snapshot.first(where: { $0.isFrontmostApp }) ?? snapshot[0]
        let frontmostPID = currentFrontmost.pid
        let frontmostBundleID = currentFrontmost.bundleIdentifier

        let liveIDs = Set(snapshot.map(\.id))
        recentWindowIDs.removeAll { !liveIDs.contains($0) }

        let itemsByID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })

        // snapshotByPID is z-ordered (CGWindowList front-to-back), so .first is
        // the z-front window of that app — the one the user most recently focused.
        let snapshotByPID = Dictionary(grouping: snapshot, by: \.pid)

        var ordered: [WindowItem] = [currentFrontmost]
        var seen: Set<WindowItem.ID> = [currentFrontmost.id]
        // PIDs whose z-front window has already been emitted. Seed with
        // frontmost (its z-front is currentFrontmost, already at position 0).
        var zFrontEmittedPIDs: Set<pid_t> = [frontmostPID]

        // When the previous switcher selection was also from the frontmost app,
        // the user is cycling within the same app and expects the sibling to
        // stay near the top. Allow exactly one same-app sibling through before
        // any cross-app window is emitted; block the rest to the end as usual.
        let lastWasSameApp = lastFromPID == frontmostPID
        var samePeerEmitted = false
        var crossAppEmitted = false

        // Cross-app pass: each window keeps its independent rank. On first
        // encounter of a non-frontmost PID, promote its z-front sibling if the
        // current id isn't already z-front — handles direct-click activations
        // where trackSystemActivation can't distinguish which window was clicked.
        for id in recentWindowIDs {
            guard let item = itemsByID[id], !seen.contains(item.id) else { continue }
            if item.pid == frontmostPID {
                // Same-app sibling: allow through only when the last selection
                // was also from this app and no cross-app window has appeared yet.
                guard lastWasSameApp, !samePeerEmitted, !crossAppEmitted else { continue }
                samePeerEmitted = true
                seen.insert(item.id)
                ordered.append(item)
                continue
            }
            crossAppEmitted = true
            if !zFrontEmittedPIDs.contains(item.pid) {
                if let zFront = snapshotByPID[item.pid]?.first, zFront.id != item.id, seen.insert(zFront.id).inserted {
                    ordered.append(zFront)
                }
                zFrontEmittedPIDs.insert(item.pid)
            }
            seen.insert(item.id)
            ordered.append(item)
        }

        // Persisted bundle order seeds the first cycle after a fresh launch
        // when `recentWindowIDs` hasn't been populated yet. Skip frontmost
        // bundle (its windows go last).
        if !recentBundleIDs.isEmpty {
            let snapshotByBundle = Dictionary(grouping: snapshot, by: { $0.bundleIdentifier })
            for bundleID in recentBundleIDs where bundleID != frontmostBundleID {
                guard let group = snapshotByBundle[bundleID] else { continue }
                for item in group where seen.insert(item.id).inserted {
                    ordered.append(item)
                }
            }
        }

        // Cross-app fallback (anything still unseen, excluding frontmost app).
        for item in snapshot where item.pid != frontmostPID && seen.insert(item.id).inserted {
            ordered.append(item)
        }

        // Frontmost app's remaining windows. When the last switch was same-app
        // (lastWasSameApp) the primary sibling is already at position 1 via the
        // cross-app pass above, so remaining siblings still go last. When the
        // last switch was cross-app the most-MRU sibling is promoted to position
        // 2 so it's reachable with one extra Tab press rather than being buried.
        var firstCrossAppSiblingPlaced = false
        for item in snapshotByPID[frontmostPID, default: []] where seen.insert(item.id).inserted {
            if !firstCrossAppSiblingPlaced, !lastWasSameApp {
                firstCrossAppSiblingPlaced = true
                ordered.insert(item, at: min(2, ordered.count))
            } else {
                ordered.append(item)
            }
        }

        return ordered
    }

    /// Records the user's choice from `liveItems` and writes the bundle list
    /// back to UserDefaults.
    func rememberSelection(_ id: CGWindowID, in liveItems: [WindowItem]) {
        lastFromPID = liveItems.first?.pid  // nil when liveItems is empty — resets same-app cycling, which is correct
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
