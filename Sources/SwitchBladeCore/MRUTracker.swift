import AppKit
import CoreGraphics
import Foundation
import os.log

/// MRU bookkeeping in two layers:
/// 1. In-memory rank entries — fine-grained, per-window, lost on relaunch.
///    Each rank stores the last concrete window ID, an app/title signature, and
///    an app identity fallback together so pruning one key cannot shift another
///    window into that rank.
/// 2. Persisted `recentBundleIDs` — coarse, per-app, survives relaunch.
///
/// `orderedForDisplay(from:)` produces the canonical switcher ordering used
/// every cold open: frontmost window first, then in-memory window recents,
/// then the persisted bundle order, then anything left in the snapshot.
@MainActor
final class MRUTracker {
    private struct RankEntry {
        var windowID: CGWindowID?
        var signature: String?
        let appIdentity: String
    }

    private var recentRanks: [RankEntry] = []

    var recentWindowIDs: [CGWindowID] {
        recentRanks.compactMap(\.windowID)
    }

    var recentWindowSignatures: [String] {
        recentRanks.compactMap(\.signature)
    }

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

    /// Builds the display order for a snapshot without mutating MRU state.
    ///
    /// Each window keeps its independent rank in `recentRanks`. Same-app
    /// windows are treated like any other windows: if a switch does not involve
    /// them, their relative positions do not change. Missing IDs are skipped for
    /// this snapshot only; a transient CGWindowList miss must not erase rank.
    func orderedForDisplay(from snapshot: [WindowItem], context: String = "unknown") -> [WindowItem] {
        guard !snapshot.isEmpty else { return [] }

        // isFrontmostApp comes from NSWorkspace at snapshot time and is more
        // accurate than snapshot.first (CGWindowList z-order lags briefly after
        // an activation).
        let currentFrontmost = snapshot.first(where: { $0.isFrontmostApp }) ?? snapshot[0]

        let itemsByID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })

        var ordered: [WindowItem] = [currentFrontmost]
        var seen: Set<WindowItem.ID> = [currentFrontmost.id]
        var diagnostics: [String] = [
            diagnosticEntry(for: currentFrontmost, rank: 0, reason: "frontmost")
        ]
        var skippedRanks: [String] = []

        // Replay the existing per-window MRU chain exactly. The only implicit
        // move is the current frontmost window at position 0. CGWindowIDs can
        // change when AppKit recreates a window, so each rank also has a
        // same-launch app/title signature fallback.
        var remainingBySignature = Dictionary(grouping: snapshot.filter { !seen.contains($0.id) },
                                               by: signature(for:))
        let itemsByAppIdentity = Dictionary(grouping: snapshot, by: appIdentity(for:))
        let currentFrontmostIdentity = appIdentity(for: currentFrontmost)
        let replayRanks = frontmostConcreteRanksFirst(
            currentFrontmostIdentity: currentFrontmostIdentity
        )
        for (rankIndex, rank) in replayRanks {
            if let windowID = rank.windowID,
               let item = itemsByID[windowID] {
                if seen.insert(item.id).inserted {
                    ordered.append(item)
                    diagnostics.append(diagnosticEntry(for: item, rank: ordered.count - 1, reason: "rankID:\(rankIndex)"))
                }
                continue
            }

            if let signature = rank.signature,
               var matches = remainingBySignature[signature],
               let matchIndex = matches.firstIndex(where: { !seen.contains($0.id) }) {
                let item = matches.remove(at: matchIndex)
                remainingBySignature[signature] = matches
                seen.insert(item.id)
                ordered.append(item)
                diagnostics.append(diagnosticEntry(for: item, rank: ordered.count - 1, reason: "rankSignature:\(rankIndex)"))
                continue
            }

            let identity = rank.appIdentity
            let unseenIdentityMatches = itemsByAppIdentity[identity, default: []]
                .filter { !seen.contains($0.id) }
            guard unseenIdentityMatches.count == 1,
                  let item = unseenIdentityMatches.first,
                  !seen.contains(item.id) else {
                skippedRanks.append(diagnosticSkippedRank(
                    rank,
                    rankIndex: rankIndex,
                    remainingCount: unseenIdentityMatches.count
                ))
                continue
            }
            seen.insert(item.id)
            ordered.append(item)
            diagnostics.append(diagnosticEntry(for: item, rank: ordered.count - 1, reason: "rankSingleAppIdentity:\(rankIndex)"))
        }

        // Persisted bundle order seeds the first cycle after a fresh launch
        // when `recentWindowIDs` hasn't been populated yet.
        if !recentBundleIDs.isEmpty {
            let snapshotByBundle = Dictionary(grouping: snapshot, by: { $0.bundleIdentifier })
            for bundleID in recentBundleIDs {
                guard let group = snapshotByBundle[bundleID] else { continue }
                for item in group where seen.insert(item.id).inserted {
                    ordered.append(item)
                    diagnostics.append(diagnosticEntry(for: item, rank: ordered.count - 1, reason: "persistedBundle"))
                }
            }
        }

        // Snapshot fallback for new windows that have no remembered rank yet.
        for item in snapshot where seen.insert(item.id).inserted {
            ordered.append(item)
            diagnostics.append(diagnosticEntry(for: item, rank: ordered.count - 1, reason: "snapshotFallback"))
        }

        logOrderingDiagnostics(
            context: context,
            snapshot: snapshot,
            diagnostics: diagnostics,
            skippedRanks: skippedRanks
        )
        return ordered
    }

    /// Records the user's choice from `liveItems` and writes the bundle list
    /// back to UserDefaults.
    ///
    /// `liveItems` may be a stale switcher snapshot (e.g. cached items shown
    /// before the fresh enumeration finishes). It is NOT an authoritative
    /// list of live windows. Existing ranks for windows missing from
    /// `liveItems` are preserved — `pruneToLive` is the only path that may
    /// drop ranks, and it is called only on explicit close/quit.
    func rememberSelection(_ id: CGWindowID, in liveItems: [WindowItem], context: String = "unknown") {
        guard let item = liveItems.first(where: { $0.id == id }) else {
            logRememberSelectionMiss(id: id, liveItems: liveItems, context: context)
            return
        }

        let rankedItems = [item] + liveItems.filter { $0.id != id }
        let freshRanks = rankedItems.map { item in
            RankEntry(
                windowID: item.id,
                signature: signature(for: item),
                appIdentity: appIdentity(for: item)
            )
        }
        let liveIDs = Set(liveItems.map(\.id))
        let liveAppIdentities = Set(liveItems.map(appIdentity(for:)))
        let preservedRanks = recentRanks.filter { rank in
            if let windowID = rank.windowID {
                return !liveIDs.contains(windowID)
            }
            // Identity-only ranks (windowID nil after prior prune) survive
            // only when the app is absent from liveItems; otherwise the fresh
            // rank above already covers it.
            return !liveAppIdentities.contains(rank.appIdentity)
        }
        recentRanks = freshRanks + preservedRanks
        logRememberSelection(item, liveItems: liveItems, context: context)

        guard let bundleID = item.bundleIdentifier,
              !bundleID.isEmpty else { return }

        recentBundleIDs.removeAll { $0 == bundleID }
        recentBundleIDs.insert(bundleID, at: 0)
        if recentBundleIDs.count > maxBundles {
            recentBundleIDs.removeLast(recentBundleIDs.count - maxBundles)
        }
        userDefaults.set(recentBundleIDs, forKey: storageKey)
    }

    /// System activation only tells us the app, not the specific window.
    /// Record an identity-only rank so single-window apps activated outside
    /// SwitchBlade do not fall to the snapshot tail. Multi-window apps are not
    /// guessed: `orderedForDisplay` uses this rank only when there is exactly
    /// one unseen live window for the app identity.
    func trackSystemActivation(
        _ pid: pid_t,
        in liveItems: [WindowItem],
        bundleIdentifier: String? = nil
    ) {
        let identity = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            ?? liveItems.first(where: { $0.pid == pid }).map(appIdentity(for:))
        guard let identity else { return }

        recentRanks.removeAll { rank in
            rank.appIdentity == identity && rank.windowID == nil && rank.signature == nil
        }
        recentRanks.insert(
            RankEntry(windowID: nil, signature: nil, appIdentity: identity),
            at: 0
        )

        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        recentBundleIDs.removeAll { $0 == bundleIdentifier }
        recentBundleIDs.insert(bundleIdentifier, at: 0)
        if recentBundleIDs.count > maxBundles {
            recentBundleIDs.removeLast(recentBundleIDs.count - maxBundles)
        }
        userDefaults.set(recentBundleIDs, forKey: storageKey)
    }

    /// Drops the rank for one specific window. Use this when you KNOW the
    /// window is gone (close/quit) — do not infer "missing means dead" from
    /// the displayed `items` list. The displayed list may be a stale cached
    /// snapshot or may not yet include minimized windows, so a sweep-style
    /// `pruneToLive(items)` would wrongly drop ranks for windows that are
    /// alive but absent from the UI's view.
    func dropRank(forID id: CGWindowID) {
        recentRanks.removeAll { $0.windowID == id }
    }

    /// Drops every rank tied to a single app identity. Use this when the user
    /// quits the entire app — every window of that pid is gone, regardless of
    /// which ones the switcher happened to display. Also clears the persisted
    /// bundle entry so the app doesn't seed back at the top of a fresh launch.
    func dropAllRanks(forAppIdentity identity: String, bundleIdentifier: String?) {
        recentRanks.removeAll { $0.appIdentity == identity }
        if let bundleIdentifier {
            recentBundleIDs.removeAll { $0 == bundleIdentifier }
            userDefaults.set(recentBundleIDs, forKey: storageKey)
        }
    }

    /// Removes IDs that no longer correspond to live items.
    ///
    /// **Caller contract**: `liveItems` MUST be an authoritative list of every
    /// live window — visible AND minimized AND any other off-screen windows.
    /// Passing a partial list (e.g. the switcher's displayed `items` while
    /// minimized merge is pending) will wrongly drop ranks of windows that
    /// are alive but missing from the view, causing them to fall to the
    /// snapshot-fallback tail on the next open. Today no production caller
    /// can guarantee this — prefer `dropRank(forID:)` or
    /// `dropAllRanks(forAppIdentity:)`.
    func pruneToLive(_ liveItems: [WindowItem]) {
        let liveIDs = Set(liveItems.map(\.id))
        let liveSignatures = Set(liveItems.map(signature(for:)))
        let liveAppIdentityCounts = Dictionary(grouping: liveItems, by: appIdentity(for:))
            .mapValues(\.count)
        var seenIdentityOnlyRanks: Set<String> = []

        recentRanks = recentRanks.compactMap { rank in
            let liveWindowID = rank.windowID.flatMap { liveIDs.contains($0) ? $0 : nil }
            let liveSignature = rank.signature.flatMap { liveSignatures.contains($0) ? $0 : nil }
            let liveAppWindowCount = liveAppIdentityCounts[rank.appIdentity] ?? 0

            guard liveWindowID != nil || liveSignature != nil || liveAppWindowCount == 1 else {
                return nil
            }

            if liveWindowID == nil && liveSignature == nil {
                guard seenIdentityOnlyRanks.insert(rank.appIdentity).inserted else {
                    return nil
                }
            }

            return RankEntry(
                windowID: liveWindowID,
                signature: liveSignature,
                appIdentity: rank.appIdentity
            )
        }
    }

    private func signature(for item: WindowItem) -> String {
        return "\(appIdentity(for: item))::\(item.displayTitle)"
    }

    private func appIdentity(for item: WindowItem) -> String {
        item.bundleIdentifier ?? item.appName
    }

    private func frontmostConcreteRanksFirst(
        currentFrontmostIdentity: String
    ) -> [(offset: Int, element: RankEntry)] {
        let concreteSameAppRanks = recentRanks.enumerated().filter { _, rank in
            rank.appIdentity == currentFrontmostIdentity
                && (rank.windowID != nil || rank.signature != nil)
        }
        guard !concreteSameAppRanks.isEmpty else {
            return Array(recentRanks.enumerated())
        }

        let concreteSameAppRankIndexes = Set(concreteSameAppRanks.map(\.offset))
        let remainingRanks = recentRanks.enumerated().filter { index, _ in
            !concreteSameAppRankIndexes.contains(index)
        }
        return concreteSameAppRanks + remainingRanks
    }

    private func diagnosticEntry(for item: WindowItem, rank: Int, reason: String) -> String {
        let frontmost = item.isFrontmostApp ? "F" : "-"
        return "\(rank):id=\(item.id),pid=\(item.pid),app=\(appIdentity(for: item)),front=\(frontmost),reason=\(reason)"
    }

    private func diagnosticSkippedRank(_ rank: RankEntry, rankIndex: Int, remainingCount: Int) -> String {
        let hasID = rank.windowID == nil ? "nil" : "set"
        let hasSignature = rank.signature == nil ? "nil" : "set"
        return "\(rankIndex):app=\(rank.appIdentity),id=\(hasID),sig=\(hasSignature),remainingCount=\(remainingCount)"
    }

    private func logOrderingDiagnostics(
        context: String,
        snapshot: [WindowItem],
        diagnostics: [String],
        skippedRanks: [String]
    ) {
        guard PerformanceLoggingState.mode == .debug else { return }
        let snapshotSummary = snapshot.prefix(16)
            .map { "id=\($0.id),pid=\($0.pid),app=\(appIdentity(for: $0)),front=\($0.isFrontmostApp ? "F" : "-")" }
            .joined(separator: ";")
        let orderSummary = diagnostics.prefix(16).joined(separator: ";")
        let skippedSummary = skippedRanks.prefix(16).joined(separator: ";")
        Logger.switcher.debug(
            "MRU order context=\(context, privacy: .public) snapshotCount=\(snapshot.count, privacy: .public) ranks=\(self.recentRanks.count, privacy: .public) bundles=\(self.recentBundleIDs.count, privacy: .public) snapshot=[\(snapshotSummary, privacy: .public)] order=[\(orderSummary, privacy: .public)] skipped=[\(skippedSummary, privacy: .public)]"
        )
    }

    private func logRememberSelection(_ item: WindowItem, liveItems: [WindowItem], context: String) {
        guard PerformanceLoggingState.mode == .debug else { return }
        let selectedIndex = liveItems.firstIndex(where: { $0.id == item.id }) ?? -1
        let itemSummary = diagnosticEntry(for: item, rank: selectedIndex, reason: "selected")
        let orderSummary = liveItems.prefix(16)
            .enumerated()
            .map { index, item in diagnosticEntry(for: item, rank: index, reason: "input") }
            .joined(separator: ";")
        Logger.switcher.debug(
            "MRU remember context=\(context, privacy: .public) selected=[\(itemSummary, privacy: .public)] liveCount=\(liveItems.count, privacy: .public) input=[\(orderSummary, privacy: .public)]"
        )
    }

    private func logRememberSelectionMiss(id: CGWindowID, liveItems: [WindowItem], context: String) {
        guard PerformanceLoggingState.mode == .debug else { return }
        let orderSummary = liveItems.prefix(16)
            .enumerated()
            .map { index, item in diagnosticEntry(for: item, rank: index, reason: "input") }
            .joined(separator: ";")
        Logger.switcher.debug(
            "MRU remember miss context=\(context, privacy: .public) selectedID=\(id, privacy: .public) liveCount=\(liveItems.count, privacy: .public) input=[\(orderSummary, privacy: .public)]"
        )
    }

}
