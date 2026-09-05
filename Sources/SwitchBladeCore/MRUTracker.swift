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

    /// App identities that currently hold only a coarse activation rank
    /// (no window ID, no signature). Diagnostic surface for tests and logs.
    var identityOnlyRankIdentities: [String] {
        recentRanks.filter(isIdentityOnly).map(\.appIdentity)
    }

    private(set) var recentBundleIDs: [String]

    private let maxBundles: Int
    private let maxRanks: Int
    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "sb_recentBundleIDs",
        maxBundles: Int = 30,
        maxRanks: Int = 200
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.maxBundles = maxBundles
        self.maxRanks = max(1, maxRanks)
        self.recentBundleIDs = (userDefaults.array(forKey: storageKey) as? [String]) ?? []
    }

    /// Builds the display order for a snapshot without mutating MRU state.
    ///
    /// Each window keeps its independent rank in `recentRanks`. Same-app
    /// windows are treated like any other windows: if a switch does not involve
    /// them, their relative positions do not change. Missing IDs are skipped for
    /// this snapshot only; a transient CGWindowList miss must not erase rank.
    func orderedForDisplay(from snapshot: [WindowItem], context: String = "unknown", snapshotDiagnosticID: String? = nil) -> [WindowItem] {
        guard !snapshot.isEmpty else { return [] }

        // isFrontmostApp comes from NSWorkspace at snapshot time and is more
        // accurate than snapshot.first (CGWindowList z-order lags briefly after
        // an activation).
        let currentFrontmost = snapshot.first(where: { $0.isFrontmostApp }) ?? snapshot[0]

        let itemsByID = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var ordered: [WindowItem] = [currentFrontmost]
        var seen: Set<WindowItem.ID> = [currentFrontmost.id]
        var diagnostics: [String] = [
            diagnosticEntry(for: currentFrontmost, rank: 0, reason: "frontmost")
        ]
        var skippedRanks: [String] = []
        var reasonCounts: [String: Int] = [:]

        // Replay the existing per-window MRU chain exactly. The only implicit
        // move is the current frontmost window at position 0. CGWindowIDs can
        // change when AppKit recreates a window, so each rank also has a
        // same-launch app/title signature fallback.
        var remainingBySignature = Dictionary(grouping: snapshot.filter { !seen.contains($0.id) },
                                               by: signature(for:))
        let itemsByAppIdentity = Dictionary(grouping: snapshot, by: appIdentity(for:))
        // A stale concrete rank may recover only a recreated/unranked window.
        // Reserve every live item that still has its own concrete ID rank for
        // that rank. Identity-only activation ranks keep their coarse app-level
        // semantics, but candidate ambiguity is always evaluated before this
        // reservation so filtering cannot turn a multi-window app into a guess.
        let concretelyRankedLiveIDs = Set(
            recentRanks.compactMap(\.windowID).filter { itemsByID[$0] != nil }
        )
        let replayRanks = replayRanksForDisplay(currentFrontmost: currentFrontmost)
        for (rankIndex, rank) in replayRanks {
            if let windowID = rank.windowID,
               let item = itemsByID[windowID] {
                if seen.insert(item.id).inserted {
                    ordered.append(item)
                    diagnostics.append(diagnosticEntry(for: item, rank: ordered.count - 1, reason: "rankID:\(rankIndex)"))
                    reasonCounts["rank_id", default: 0] += 1
                }
                continue
            }

            if let signature = rank.signature,
               var matches = remainingBySignature[signature] {
                let unseenSignatureMatches = matches.filter { !seen.contains($0.id) }
                if unseenSignatureMatches.count == 1,
                   let item = unseenSignatureMatches.first,
                   !concretelyRankedLiveIDs.contains(item.id),
                   let matchIndex = matches.firstIndex(where: { $0.id == item.id }) {
                    matches.remove(at: matchIndex)
                    remainingBySignature[signature] = matches
                    seen.insert(item.id)
                    ordered.append(item)
                    diagnostics.append(diagnosticEntry(for: item, rank: ordered.count - 1, reason: "rankSignature:\(rankIndex)"))
                    reasonCounts["rank_signature", default: 0] += 1
                    continue
                }
            }

            let identity = rank.appIdentity
            let unseenIdentityMatches = itemsByAppIdentity[identity, default: []]
                .filter { !seen.contains($0.id) }
            guard unseenIdentityMatches.count == 1,
                  let item = unseenIdentityMatches.first,
                  !seen.contains(item.id),
                  isIdentityOnly(rank) || !concretelyRankedLiveIDs.contains(item.id) else {
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
            reasonCounts["rank_identity", default: 0] += 1
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
                    reasonCounts["persisted_bundle", default: 0] += 1
                }
            }
        }

        // Snapshot fallback for new windows that have no remembered rank yet.
        for item in snapshot where seen.insert(item.id).inserted {
            ordered.append(item)
            diagnostics.append(diagnosticEntry(for: item, rank: ordered.count - 1, reason: "snapshotFallback"))
            reasonCounts["snapshot_fallback", default: 0] += 1
        }

        logOrderingDiagnostics(
            context: context,
            snapshot: snapshot,
            diagnostics: diagnostics,
            skippedRanks: skippedRanks
        )
        PerformanceDiagnostics.$correlationID.withValue(snapshotDiagnosticID ?? UUID().uuidString) {
            recordOrderingDiagnostics(
                context: context,
                snapshot: snapshot,
                frontmost: currentFrontmost,
                diagnostics: diagnostics,
                skippedRanks: skippedRanks,
                reasonCounts: reasonCounts
            )
        }
        return ordered
    }

    /// Records the user's choice from `liveItems` and writes the bundle list
    /// back to UserDefaults.
    ///
    /// `liveItems` may be a stale switcher snapshot (e.g. cached items shown
    /// before the fresh enumeration finishes) or a partial one (minimized
    /// merge still pending, other-Space windows filtered out). It is NOT an
    /// authoritative list of live windows, so the mutation must stay minimal:
    /// move only the selected window's rank to the front and leave every
    /// other rank's position untouched. Rebuilding the whole list from
    /// `liveItems` demoted every rank missing from a partial list behind all
    /// live windows — windows drifted to the switcher tail on each commit.
    func rememberSelection(_ id: CGWindowID, in liveItems: [WindowItem], context: String = "unknown") {
        guard let item = liveItems.first(where: { $0.id == id }) else {
            logRememberSelectionMiss(id: id, liveItems: liveItems, context: context)
            return
        }

        let existingIndex = promoteConcreteRank(for: item)
        refreshLiveRankBindings(liveItems: liveItems, excluding: item.id)
        trimRanksToCapacity()
        logRememberSelection(item, movedFromIndex: existingIndex, liveItems: liveItems, context: context)

        guard let bundleID = item.bundleIdentifier else { return }
        promoteRecentBundle(bundleID)
    }

    /// Records a concrete rank for the window an external activation (click,
    /// Dock) landed on. `trackSystemActivation` records the coarse app-level
    /// hint immediately; this upgrade replaces it once the focused window has
    /// been resolved via AX — without it, windows of multi-window apps used
    /// outside the switcher never gain per-window rank and sink toward the
    /// snapshot tail.
    func trackFocusedWindowActivation(_ item: WindowItem, context: String = "system-activation-focus") {
        let movedFromIndex = promoteConcreteRank(for: item)
        trimRanksToCapacity()
        logRememberSelection(item, movedFromIndex: movedFromIndex, liveItems: [item], context: context)

        guard let bundleID = item.bundleIdentifier else { return }
        promoteRecentBundle(bundleID)
    }

    /// Records the exact window an app left focused when it moved to the
    /// background. The newly-frontmost app already owns rank 0, so the
    /// backgrounded window belongs immediately behind it. This matters when a
    /// new sibling window was created after the switcher's open-items cache:
    /// without a concrete rank it would enter later through snapshot fallback
    /// and appear in the middle or at the tail of the switcher.
    func trackBackgroundedWindowFocus(_ item: WindowItem, context: String = "backgrounded-app-focus") {
        let movedFromIndex = promoteConcreteRank(for: item, insertionIndex: 1)
        trimRanksToCapacity()
        logRememberSelection(item, movedFromIndex: movedFromIndex, liveItems: [item], context: context)
    }

    /// Moves the concrete rank for `item` to `insertionIndex`, creating it if
    /// needed. Normal focus tracking uses rank 0; a just-backgrounded window
    /// uses rank 1 behind the newly-frontmost app.
    /// ID match only: rebinding by signature would let a same-titled sibling
    /// steal the rank of a window that is merely absent from a partial list —
    /// absence never proves death. Recreated windows recover via the
    /// display-side signature fallback in `orderedForDisplay` instead.
    /// Also drops the app's identity-only rank: once the exact window is
    /// known, the coarse app-level hint would only pull an unrelated sibling
    /// forward on the next open.
    private func promoteConcreteRank(for item: WindowItem, insertionIndex: Int = 0) -> Int? {
        let existingIndex = recentRanks.firstIndex(where: { $0.windowID == item.id })
        var selectedRank = existingIndex.map { recentRanks.remove(at: $0) }
            ?? RankEntry(windowID: nil, signature: nil, appIdentity: appIdentity(for: item))
        selectedRank.windowID = item.id
        selectedRank.signature = signature(for: item)
        let identity = appIdentity(for: item)
        recentRanks.removeAll { $0.appIdentity == identity && isIdentityOnly($0) }
        recentRanks.insert(selectedRank, at: min(insertionIndex, recentRanks.count))
        return existingIndex
    }

    /// Refreshes the signature bound to each live window's ID-matched rank so
    /// title churn stays recorded. Positions never change here.
    private func refreshLiveRankBindings(liveItems: [WindowItem], excluding selectedID: CGWindowID) {
        guard !recentRanks.isEmpty else { return }
        var itemsByID: [CGWindowID: WindowItem] = [:]
        for item in liveItems where item.id != selectedID {
            itemsByID[item.id] = item
        }
        guard !itemsByID.isEmpty else { return }

        for index in recentRanks.indices {
            guard let windowID = recentRanks[index].windowID,
                  let item = itemsByID[windowID] else { continue }
            recentRanks[index].signature = signature(for: item)
        }
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
        trimRanksToCapacity()

        guard let bundleIdentifier else { return }
        promoteRecentBundle(bundleIdentifier)
    }

    /// Moves a bundle id to the front of the persisted recents and writes it
    /// back. No-op — and no UserDefaults write — when it's already at the front.
    /// `trackSystemActivation` runs on every foreground app switch, so the
    /// already-front skip keeps that hot path from rewriting UserDefaults on
    /// every click between apps.
    private func promoteRecentBundle(_ bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty, recentBundleIDs.first != bundleIdentifier else { return }
        recentBundleIDs.removeAll { $0 == bundleIdentifier }
        recentBundleIDs.insert(bundleIdentifier, at: 0)
        if recentBundleIDs.count > maxBundles {
            recentBundleIDs.removeLast(recentBundleIDs.count - maxBundles)
        }
        userDefaults.set(recentBundleIDs, forKey: storageKey)
    }

    /// Bounds the in-memory rank list so a long session can't grow
    /// `orderedForDisplay`'s per-open scan without limit. Newest ranks sit at
    /// the front, so the least-recently-touched tail is dropped first.
    private func trimRanksToCapacity() {
        guard recentRanks.count > maxRanks else { return }
        recentRanks.removeLast(recentRanks.count - maxRanks)
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

    private func replayRanksForDisplay(currentFrontmost: WindowItem) -> [(offset: Int, element: RankEntry)] {
        // Identity-only activation ranks are coarse app-level hints. They may
        // defer behind the concrete same-app rank cluster that contains the
        // current frontmost window. They must not gather unrelated sibling
        // windows for that app from elsewhere in the MRU chain.
        let currentFrontmostIdentity = appIdentity(for: currentFrontmost)
        guard let frontmostRankIndex = frontmostRankIndex(for: currentFrontmost) else {
            return Array(recentRanks.enumerated())
        }
        let frontmostCluster = concreteRankCluster(
            containing: frontmostRankIndex,
            identity: currentFrontmostIdentity
        )
        guard frontmostCluster.lowerBound > recentRanks.startIndex else {
            return Array(recentRanks.enumerated())
        }

        let previousIndex = recentRanks.index(before: frontmostCluster.lowerBound)
        let previousRank = recentRanks[previousIndex]
        guard isIdentityOnly(previousRank),
              previousRank.appIdentity != currentFrontmostIdentity else {
            return Array(recentRanks.enumerated())
        }

        var replayRanks: [(offset: Int, element: RankEntry)] = []
        replayRanks.append(contentsOf: rankEntries(in: recentRanks.startIndex..<previousIndex))
        replayRanks.append(contentsOf: rankEntries(in: frontmostCluster))
        replayRanks.append((previousIndex, previousRank))
        let afterClusterIndex = recentRanks.index(after: frontmostCluster.upperBound)
        replayRanks.append(contentsOf: rankEntries(in: afterClusterIndex..<recentRanks.endIndex))
        return replayRanks
    }

    private func rankEntries(in range: Range<Int>) -> [(offset: Int, element: RankEntry)] {
        range.map { ($0, recentRanks[$0]) }
    }

    private func rankEntries(in range: ClosedRange<Int>) -> [(offset: Int, element: RankEntry)] {
        range.map { ($0, recentRanks[$0]) }
    }

    private func concreteRankCluster(containing rankIndex: Int, identity: String) -> ClosedRange<Int> {
        var lower = rankIndex
        while lower > recentRanks.startIndex {
            let previousIndex = recentRanks.index(before: lower)
            let previousRank = recentRanks[previousIndex]
            guard previousRank.appIdentity == identity, isConcrete(previousRank) else {
                break
            }
            lower = previousIndex
        }

        var upper = rankIndex
        while upper < recentRanks.index(before: recentRanks.endIndex) {
            let nextIndex = recentRanks.index(after: upper)
            let nextRank = recentRanks[nextIndex]
            guard nextRank.appIdentity == identity, isConcrete(nextRank) else {
                break
            }
            upper = nextIndex
        }

        return lower...upper
    }

    private func frontmostRankIndex(for currentFrontmost: WindowItem) -> Int? {
        if let idIndex = recentRanks.firstIndex(where: { $0.windowID == currentFrontmost.id }) {
            return idIndex
        }
        let currentSignature = signature(for: currentFrontmost)
        let signatureIndexes = recentRanks.indices.filter { recentRanks[$0].signature == currentSignature }
        return signatureIndexes.count == 1 ? signatureIndexes[0] : nil
    }

    private func isIdentityOnly(_ rank: RankEntry) -> Bool {
        rank.windowID == nil && rank.signature == nil
    }

    private func isConcrete(_ rank: RankEntry) -> Bool {
        rank.windowID != nil || rank.signature != nil
    }

    private func diagnosticEntry(for item: WindowItem, rank: Int, reason: String) -> String {
        let frontmost = item.isFrontmostApp ? "F" : "-"
        return "\(rank):id=\(item.id),pid=\(item.pid),front=\(frontmost),reason=\(reason)"
    }

    private func diagnosticSkippedRank(_ rank: RankEntry, rankIndex: Int, remainingCount: Int) -> String {
        let hasID = rank.windowID == nil ? "nil" : "set"
        let hasSignature = rank.signature == nil ? "nil" : "set"
        return "\(rankIndex):id=\(hasID),sig=\(hasSignature),remainingCount=\(remainingCount)"
    }

    private func logOrderingDiagnostics(
        context: String,
        snapshot: [WindowItem],
        diagnostics: [String],
        skippedRanks: [String]
    ) {
        guard PerformanceLoggingState.mode == .debug else { return }
        let snapshotSummary = snapshot.prefix(16)
            .map { "id=\($0.id),pid=\($0.pid),front=\($0.isFrontmostApp ? "F" : "-")" }
            .joined(separator: ";")
        let orderSummary = diagnostics.prefix(16).joined(separator: ";")
        let skippedSummary = skippedRanks.prefix(16).joined(separator: ";")
        Logger.switcher.debug(
            "MRU order context=\(context, privacy: .public) snapshotCount=\(snapshot.count, privacy: .public) ranks=\(self.recentRanks.count, privacy: .public) bundles=\(self.recentBundleIDs.count, privacy: .public) snapshot=[\(snapshotSummary, privacy: .public)] order=[\(orderSummary, privacy: .public)] skipped=[\(skippedSummary, privacy: .public)]"
        )
    }

    /// JSONL twin of `logOrderingDiagnostics`: os_log debug lines are not
    /// persisted to disk, so performance.jsonl is the only channel that can
    /// tie an ordering decision to a later symptom report.
    private func recordOrderingDiagnostics(
        context: String,
        snapshot: [WindowItem],
        frontmost: WindowItem,
        diagnostics: [String],
        skippedRanks: [String],
        reasonCounts: [String: Int]
    ) {
        guard PerformanceDiagnostics.isEnabled else { return }
        PerformanceDiagnostics.recordWindowOrder("mru_snapshot", items: snapshot, fields: ["context": .string(context)])
        let frontmostSamePidCount = snapshot.reduce(0) { $0 + ($1.pid == frontmost.pid ? 1 : 0) }
        var fields: [String: PerformanceMetricValue] = [
            "bundle_count": .int(recentBundleIDs.count),
            "context": .string(context),
            "frontmost_pid": .int(Int(frontmost.pid)),
            "frontmost_same_pid_count": .int(frontmostSamePidCount),
            "frontmost_window_id": .int(Int(frontmost.id)),
            "rank_count": .int(recentRanks.count),
            "skipped_rank_count": .int(skippedRanks.count),
            "snapshot_count": .int(snapshot.count)
        ]
        for (reason, count) in reasonCounts {
            fields["reason_\(reason)"] = .int(count)
        }
        if !skippedRanks.isEmpty {
            fields["skipped"] = .string(skippedRanks.prefix(8).joined(separator: ";"))
        }
        PerformanceDiagnostics.recordRows("mru_order", fields: fields, rows: diagnostics)
    }

    private func logRememberSelection(_ item: WindowItem, movedFromIndex: Int?, liveItems: [WindowItem], context: String) {
        guard PerformanceLoggingState.mode == .debug else { return }
        PerformanceDiagnostics.record(
            "mru_remember",
            fields: [
                "context": .string(context),
                "live_count": .int(liveItems.count),
                "moved_from_rank": .int(movedFromIndex ?? -1),
                "rank_count": .int(recentRanks.count),
                "selected_pid": .int(Int(item.pid)),
                "selected_window_id": .int(Int(item.id))
            ]
        )
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
        PerformanceDiagnostics.record(
            "mru_remember_miss",
            fields: [
                "context": .string(context),
                "live_count": .int(liveItems.count),
                "selected_window_id": .int(Int(id))
            ]
        )
        let orderSummary = liveItems.prefix(16)
            .enumerated()
            .map { index, item in diagnosticEntry(for: item, rank: index, reason: "input") }
            .joined(separator: ";")
        Logger.switcher.debug(
            "MRU remember miss context=\(context, privacy: .public) selectedID=\(id, privacy: .public) liveCount=\(liveItems.count, privacy: .public) input=[\(orderSummary, privacy: .public)]"
        )
    }

}
