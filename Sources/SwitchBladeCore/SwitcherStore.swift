import Carbon.HIToolbox
import Foundation
import os.log
import SwiftUI

/// Observable store backing the SwitcherView. Holds the visible items + the
/// current selection and coordinates between the catalog (window listing),
/// activator (window activation/close/quit/hide), and permission service.
///
/// Preview caching and MRU bookkeeping live in dedicated helper types
/// (`PreviewCacheStore`, `MRUTracker`) — this class only orchestrates them.
@MainActor
final class SwitcherStore: ObservableObject {
    @Published private(set) var items: [WindowItem] = []
    @Published private(set) var isVisible = false
    @Published private(set) var permissionState: PermissionState
    @Published var selectedID: WindowItem.ID?

    var onShow: (() -> Void)?
    var onHide: (() -> Void)?

    /// True from the moment the first Cmd+Tab fires until the panel is hidden.
    /// Used so Command-release is detected even when the async show is still in flight.
    private(set) var isSwitching = false

    private let catalog: WindowSnapshotProviding
    private let activator: WindowActivating
    private let permissionService: PermissionProviding
    private let previewCache: PreviewCacheStore
    private let mruTracker: MRUTracker
    private let performanceMetrics: SwitcherPerformanceMetrics

    private var previewLoadTask: Task<Void, Never>?
    private var previewGeneration = 0
    nonisolated(unsafe) private var activationObserver: Any?
    /// Prevents the tile under the mouse from stealing selection when the panel first appears.
    private var hoverEnabled = false

    /// Timestamp of the most recent Cmd+Tab cycle. Used by handleAppActivation
    /// to decide whether the user is actively switcher-using and therefore
    /// worth keeping the SCKit cache warm for. Initialised so the first launch
    /// gets a warmup grace window after `applicationDidFinishLaunching`.
    private var lastSwitcherUse: Date = Date()
    /// Don't warm SCKit for app activations more than this long after the user
    /// last touched the switcher. Keeps the cost truly zero for idle users.
    /// Injectable so tests can shorten the window without sleeping for a minute.
    private let activationWarmupWindow: TimeInterval

    init(
        catalog: WindowSnapshotProviding,
        activator: WindowActivating,
        permissionService: PermissionProviding,
        userDefaults: UserDefaults = .standard,
        previewCache: PreviewCacheStore = PreviewCacheStore(),
        mruTracker: MRUTracker? = nil,
        performanceMetrics: SwitcherPerformanceMetrics = SwitcherPerformanceMetrics(),
        activationWarmupWindow: TimeInterval = 60
    ) {
        self.catalog = catalog
        self.activator = activator
        self.permissionService = permissionService
        self.permissionState = permissionService.currentState()
        self.previewCache = previewCache
        self.mruTracker = mruTracker ?? MRUTracker(userDefaults: userDefaults)
        self.performanceMetrics = performanceMetrics
        self.activationWarmupWindow = activationWarmupWindow

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Pull the pid out before bridging actors so we don't transfer the
            // non-Sendable Notification across the isolation boundary. queue:
            // .main guarantees we're already on the main thread; assumeIsolated
            // just appeases the compiler.
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid else { return }
                self.handleAppActivation(pid: pid)
            }
        }
    }

    /// Internal entry point for the NSWorkspace activation observer, also
    /// callable directly from tests so the notification queue / RunLoop
    /// plumbing doesn't have to be exercised under XCTest.
    func handleAppActivation(pid: pid_t) {
        if !isVisible {
            mruTracker.trackSystemActivation(pid: pid, in: items)
        }
        // Opportunistic SCKit cache warmup — gated on recent-use so we don't
        // burn cycles for users who haven't touched the switcher in a while.
        // The cache's IfStale check is a second throttle layer (no SCKit call
        // when cache is fresh), but this outer gate ensures we don't even
        // hit the actor for idle users.
        guard Date().timeIntervalSince(lastSwitcherUse) < activationWarmupWindow else { return }
        let catalogRef = self.catalog
        Task.detached(priority: .utility) {
            await catalogRef.refreshContentCacheIfStale()
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func refreshPermissionState() {
        permissionState = permissionService.currentState()
    }

    func invalidateCaptureCache(reason: String) {
        let catalogRef = self.catalog
        Task.detached(priority: .utility) {
            await catalogRef.invalidateContentCache(reason: reason)
        }
    }

    func cycle(forward: Bool) {
        // Mark "the user is using the switcher right now" so handleAppActivation
        // knows it's worth warming the SCKit cache on app switches for the next
        // ~minute. Idle users (haven't pressed Cmd+Tab in a while) skip the warmup.
        lastSwitcherUse = Date()
        permissionState = permissionService.currentState()

        if !isVisible {
            let openStart = Date()
            isSwitching = true
            previewLoadTask?.cancel()
            let visibleSnapshot = catalog.snapshotVisibleOnly()
            let orderedItems = mruTracker.orderedForDisplay(from: visibleSnapshot)
            guard !orderedItems.isEmpty else {
                isSwitching = false
                Logger.switcher.notice("Cycle aborted: snapshot is empty")
                return
            }

            items = orderedItems.map(previewCache.hydrated)
            // Preselect the second item so a tap-Cmd+Tab+release toggles between
            // the two most-recent windows. With only one item, select that.
            selectedID = items.indices.contains(1) ? items[1].id : items.first?.id

            let cachedHits = items.filter { $0.preview != nil }.count
            let coldMs = Date().timeIntervalSince(openStart) * 1000
            let coldSummary = performanceMetrics.recordColdOpen(milliseconds: coldMs)
            Logger.switcher.info(
                "Cold-open: \(orderedItems.count, privacy: .public) windows in \(coldMs, format: .fixed(precision: 1), privacy: .public) ms, \(cachedHits, privacy: .public) from cache; rolling n=\(coldSummary.count, privacy: .public), avg=\(coldSummary.average, format: .fixed(precision: 1), privacy: .public), p95=\(coldSummary.p95, format: .fixed(precision: 1), privacy: .public), p99=\(coldSummary.p99, format: .fixed(precision: 1), privacy: .public), max=\(coldSummary.max, format: .fixed(precision: 1), privacy: .public)"
            )
            showWithPreviews()

            // Lazily fetch minimized windows off the main thread and merge them in.
            // The AX walk is ~150–500ms with many apps — running it here would block
            // the panel from appearing.
            let mergeGeneration = previewGeneration
            let catalog = self.catalog
            Task.detached(priority: .userInitiated) { [weak self] in
                let minimized = await catalog.snapshotMinimized()
                await self?.mergeMinimizedItems(minimized, generation: mergeGeneration)
            }
            return
        }

        moveSelection(forward ? 1 : -1)
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isVisible else {
            return false
        }

        switch Int(event.keyCode) {
        case Int(kVK_Tab):
            moveSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case Int(kVK_RightArrow), Int(kVK_DownArrow):
            moveSelection(1)
            return true
        case Int(kVK_LeftArrow), Int(kVK_UpArrow):
            moveSelection(-1)
            return true
        case Int(kVK_Home):
            selectFirst()
            return true
        case Int(kVK_End):
            selectLast()
            return true
        case Int(kVK_ANSI_Q) where event.modifierFlags.contains(.command):
            quitSelectedApp()
            return true
        case Int(kVK_ANSI_H) where event.modifierFlags.contains(.command):
            hideSelectedApp()
            return true
        case Int(kVK_Return), Int(kVK_Space):
            commitSelection()
            return true
        case Int(kVK_Escape):
            cancel()
            return true
        default:
            return false
        }
    }

    private func selectFirst() {
        guard let first = items.first else { return }
        selectedID = first.id
    }

    private func selectLast() {
        guard let last = items.last else { return }
        selectedID = last.id
    }

    func hover(_ item: WindowItem) {
        guard hoverEnabled else { return }
        selectedID = item.id
    }

    func choose(_ item: WindowItem) {
        selectedID = item.id
        commitSelection()
    }

    func close(_ item: WindowItem) {
        activator.close(item)
        removeItem(withID: item.id)
    }

    /// Quits the entire app of the selected window. The switcher hides; if
    /// other windows of the same pid are also listed, they're removed too.
    private func quitSelectedApp() {
        guard let selected = selectedItem else { return }
        activator.quit(selected)
        items.removeAll { $0.pid == selected.pid }
        mruTracker.pruneToLive(items)
        if items.isEmpty {
            cancel()
        } else {
            hide()
        }
    }

    /// Hides all windows of the selected app, keeping the app running. The
    /// switcher closes; the items list is intact for the next cold open.
    private func hideSelectedApp() {
        guard let selected = selectedItem else { return }
        activator.hide(selected)
        hide()
    }

    func commitSelection() {
        guard let item = selectedItem else {
            cancel()
            return
        }

        mruTracker.rememberSelection(item.id, in: items)
        hide()
        // Defer past the current RunLoop cycle so panel.orderOut renders before
        // WindowActivator starts synchronous AX IPC to the target app.
        let activator = self.activator
        Task { @MainActor in
            activator.activate(item)
        }
    }

    func cancel() {
        hide()
    }

    private var selectedItem: WindowItem? {
        items.first(where: { $0.id == selectedID })
    }

    private func hide() {
        previewGeneration += 1
        previewLoadTask?.cancel()
        previewLoadTask = nil
        isVisible = false
        isSwitching = false
        hoverEnabled = false
        onHide?()
    }

    private func showWithPreviews() {
        let windowIDs = items.filter { !$0.isMinimized }.map(\.windowID)

        previewGeneration += 1
        let generation = previewGeneration

        guard !windowIDs.isEmpty else {
            hoverEnabled = false
            isVisible = true
            onShow?()
            scheduleHoverEnable(generation: generation)
            return
        }

        let initialPreviewCount = min(10, windowIDs.count)
        let catalog = self.catalog

        hoverEnabled = false
        isVisible = true
        onShow?()
        scheduleHoverEnable(generation: generation)

        previewLoadTask = Task {
            let batchStart = Date()
            let previews = await catalog.capturePreviews(
                for: windowIDs,
                maxCount: initialPreviewCount,
                maxConcurrentCaptures: 6
            )

            guard !Task.isCancelled else { return }
            let firstBatchMs = Date().timeIntervalSince(batchStart) * 1000
            let successRate = windowIDs.isEmpty ? 0
                : Double(previews.count) / Double(min(initialPreviewCount, windowIDs.count))
            let batchSummary = self.performanceMetrics.recordFirstPreviewBatch(milliseconds: firstBatchMs)
            Logger.switcher.info(
                "First preview batch: \(previews.count, privacy: .public)/\(min(initialPreviewCount, windowIDs.count), privacy: .public) in \(firstBatchMs, format: .fixed(precision: 1), privacy: .public) ms (rate \(successRate, format: .fixed(precision: 2), privacy: .public)); rolling n=\(batchSummary.count, privacy: .public), avg=\(batchSummary.average, format: .fixed(precision: 1), privacy: .public), p95=\(batchSummary.p95, format: .fixed(precision: 1), privacy: .public), p99=\(batchSummary.p99, format: .fixed(precision: 1), privacy: .public), max=\(batchSummary.max, format: .fixed(precision: 1), privacy: .public)"
            )
            self.applyPreviews(previews, generation: generation)

            let deferredWindowIDs = windowIDs.filter { previews[$0] == nil }
            if !deferredWindowIDs.isEmpty {
                let allPreviews = await catalog.capturePreviews(
                    for: deferredWindowIDs,
                    maxCount: nil,
                    maxConcurrentCaptures: 6
                )
                guard !Task.isCancelled else { return }
                self.applyPreviews(allPreviews, generation: generation)
            }

            // Refresh SC content cache so the next Cmd+Tab is warm.
            // Detached so a fast Cmd+Tab+release (which cancels previewLoadTask)
            // still leaves the cache fresh — otherwise the next switch hits a
            // stale cache and previews load slowly.
            Task.detached(priority: .utility) { [catalog] in
                await catalog.refreshContentCache()
            }
        }
    }

    private func applyPreviews(_ previews: [CGWindowID: NSImage], generation: Int) {
        guard isVisible, previewGeneration == generation else { return }
        previewCache.record(previews, liveItems: items)
        items = items.map { item in
            previews[item.windowID].map { item.withPreview($0) } ?? item
        }
    }

    private func mergeMinimizedItems(_ minimized: [WindowItem], generation: Int) {
        guard isVisible, previewGeneration == generation, !minimized.isEmpty else { return }
        let existingIDs = Set(items.map(\.id))
        let newItems = minimized
            .filter { !existingIDs.contains($0.id) }
            .map(previewCache.hydrated)
        guard !newItems.isEmpty else { return }
        items = items + newItems
    }

    private func scheduleHoverEnable(generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, self.previewGeneration == generation else { return }
            self.hoverEnabled = true
        }
    }

    private func removeItem(withID id: WindowItem.ID) {
        let removedIndex = items.firstIndex(where: { $0.id == id })
        items.removeAll { $0.id == id }
        mruTracker.pruneToLive(items)

        guard !items.isEmpty else {
            cancel()
            return
        }

        if selectedID == id {
            let nextIndex = min(removedIndex ?? 0, items.count - 1)
            selectedID = items[nextIndex].id
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else {
            return
        }

        let currentIndex = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        let nextIndex = (currentIndex + delta + items.count) % items.count
        selectedID = items[nextIndex].id
    }
}
