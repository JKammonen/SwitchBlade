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
    var onOpenSettings: (() -> Void)?

    /// True from the moment the first Cmd+Tab fires until the panel is hidden.
    /// Used so Command-release is detected even when the async show is still in flight.
    private(set) var isSwitching = false

    private let catalog: WindowSnapshotProviding
    private let activator: WindowActivating
    private let permissionService: PermissionProviding
    private let previewCache: PreviewCacheStore
    private let mruTracker: MRUTracker
    private let performanceMetrics: SwitcherPerformanceMetrics
    private let switchBladePID: pid_t

    private var previewLoadTask: Task<Void, Never>?
    private var contentCacheWarmupTask: Task<Void, Never>?
    private var openItemsWarmupTask: Task<Void, Never>?
    private var previewWarmupTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var commitWhenOpenCompletes = false
    private var pendingOpenRequestedAt: Date?
    private var cachedOpenItems: [WindowItem] = []
    private var cachedOpenItemsUpdatedAt: Date?
    nonisolated(unsafe) private var activationObserver: Any?
    /// Prevents the tile under the mouse from stealing selection when the panel first appears.
    private var hoverEnabled = false
    private var currentAppPID: pid_t?
    private var previousAppPID: pid_t?

    /// Timestamp of the most recent Cmd+Tab cycle. Used by handleAppActivation
    /// to decide whether the user is actively switcher-using and therefore
    /// worth keeping the SCKit cache warm for. Initialised so the first launch
    /// gets a warmup grace window after `applicationDidFinishLaunching`.
    private var lastSwitcherUse: Date = Date()
    /// Don't warm SCKit for app activations more than this long after the user
    /// last touched the switcher. Keeps the cost truly zero for idle users.
    /// Injectable so tests can shorten the window without sleeping for a minute.
    private let activationWarmupWindow: TimeInterval
    private let cachedOpenItemsMaxAge: TimeInterval

    init(
        catalog: WindowSnapshotProviding,
        activator: WindowActivating,
        permissionService: PermissionProviding,
        userDefaults: UserDefaults = .standard,
        previewCache: PreviewCacheStore = PreviewCacheStore(),
        mruTracker: MRUTracker? = nil,
        performanceMetrics: SwitcherPerformanceMetrics = SwitcherPerformanceMetrics(),
        activationWarmupWindow: TimeInterval = 60,
        cachedOpenItemsMaxAge: TimeInterval = 30,
        initialFrontmostAppPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier,
        switchBladePID: pid_t = getpid()
    ) {
        self.catalog = catalog
        self.activator = activator
        self.permissionService = permissionService
        self.permissionState = permissionService.currentState()
        self.previewCache = previewCache
        self.mruTracker = mruTracker ?? MRUTracker(userDefaults: userDefaults)
        self.performanceMetrics = performanceMetrics
        self.activationWarmupWindow = activationWarmupWindow
        self.cachedOpenItemsMaxAge = cachedOpenItemsMaxAge
        self.currentAppPID = initialFrontmostAppPID
        self.switchBladePID = switchBladePID

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
        if pid != switchBladePID, !isVisible, !isSwitching {
            if currentAppPID != pid {
                previousAppPID = currentAppPID
                currentAppPID = pid
            }
            mruTracker.trackSystemActivation(pid: pid, in: items)
        }
        // Opportunistic cache warmup — gated on recent-use so we don't burn
        // cycles for users who haven't touched the switcher in a while.
        guard Date().timeIntervalSince(lastSwitcherUse) < activationWarmupWindow else { return }
        scheduleContentCacheWarmup(delayNanoseconds: 250_000_000)
        scheduleOpenItemsCacheWarmup(context: "app activation", delayNanoseconds: 250_000_000)
    }

    deinit {
        contentCacheWarmupTask?.cancel()
        openItemsWarmupTask?.cancel()
        previewWarmupTask?.cancel()
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

    func warmPreviewCache(context: String) async {
        guard SwitchBladeSettings.shared.previewMode != .iconsOnly else { return }
        guard !isVisible, !isSwitching else { return }

        let visibleSnapshot = await snapshotVisibleOnlyOffMain()
        guard !Task.isCancelled, !isVisible, !isSwitching else { return }
        let orderedItems = orderItems(mruTracker.orderedForDisplay(from: visibleSnapshot))
        updateCachedOpenItems(orderedItems)
        let windowIDs = orderedItems
            .filter { !$0.isMinimized && $0.canCapturePreview }
            .map(\.windowID)
        let initialWindowIDs = Array(windowIDs.prefix(10))
        guard !initialWindowIDs.isEmpty else { return }
        guard !Task.isCancelled else { return }

        let start = Date()
        let previews = await catalog.capturePreviews(
            for: initialWindowIDs,
            maxCount: nil,
            maxConcurrentCaptures: min(4, initialWindowIDs.count)
        )
        guard !Task.isCancelled, !isVisible, !isSwitching else { return }
        let acceptedPreviews = previewCache.record(previews, liveItems: orderedItems)
        let ms = Date().timeIntervalSince(start) * 1000
        Logger.switcher.info(
            "Preview cache warmup (\(context, privacy: .public)): \(acceptedPreviews.count, privacy: .public)/\(initialWindowIDs.count, privacy: .public) in \(ms, format: .fixed(precision: 1), privacy: .public) ms"
        )
    }

    func cycle(forward: Bool) {
        Logger.switcher.notice("cycle: enter isVisible=\(self.isVisible, privacy: .public)")
        // Mark "the user is using the switcher right now" so handleAppActivation
        // knows it's worth warming the SCKit cache on app switches for the next
        // ~minute. Idle users (haven't pressed Cmd+Tab in a while) skip the warmup.
        lastSwitcherUse = Date()
        contentCacheWarmupTask?.cancel()
        openItemsWarmupTask?.cancel()
        previewWarmupTask?.cancel()
        let permissionStart = Date()
        permissionState = permissionService.currentState()
        let permissionMs = Date().timeIntervalSince(permissionStart) * 1000

        if !isVisible {
            let openStart = Date()
            let queueMs = pendingOpenRequestedAt.map { openStart.timeIntervalSince($0) * 1000 } ?? 0
            pendingOpenRequestedAt = nil
            isSwitching = true
            previewLoadTask?.cancel()
            let snapshotStart = Date()
            let visibleSnapshot = catalog.snapshotVisibleOnly()
            let snapshotMs = Date().timeIntervalSince(snapshotStart) * 1000
            let orderStart = Date()
            let orderedItems = orderItems(mruTracker.orderedForDisplay(from: visibleSnapshot))
            let orderMs = Date().timeIntervalSince(orderStart) * 1000
            openFromOrderedItems(
                orderedItems,
                openStart: openStart,
                queueMs: queueMs,
                permissionMs: permissionMs,
                snapshotMs: snapshotMs,
                orderMs: orderMs,
                source: "snapshot"
            )
            return
        }

        moveSelection(forward ? 1 : -1)
    }

    /// Entry point for the CGEventTap hotkey callback. Keep this cheap so
    /// macOS does not disable the tap while SwitchBlade enumerates windows.
    func requestCycle(forward: Bool) {
        Logger.switcher.notice("requestCycle: enter isVisible=\(self.isVisible, privacy: .public) isSwitching=\(self.isSwitching, privacy: .public)")
        if isVisible {
            cycle(forward: forward)
            return
        }
        // Two rapid Cmd+Tab events arrive before the async open completes: the
        // second call would post another cycle() task and double-fire the preview
        // load. Drop it — the in-flight open already covers this key-down.
        guard !isSwitching else { return }

        lastSwitcherUse = Date()
        contentCacheWarmupTask?.cancel()
        openItemsWarmupTask?.cancel()
        previewWarmupTask?.cancel()
        pendingOpenRequestedAt = Date()
        isSwitching = true

        if !cachedOpenItems.isEmpty {
            let openStart = Date()
            let isStale = !isCachedOpenItemsFresh()
            pendingOpenRequestedAt = nil
            openFromOrderedItems(
                cachedOpenItems,
                openStart: openStart,
                queueMs: nil,
                permissionMs: 0,
                snapshotMs: 0,
                orderMs: 0,
                source: isStale ? "stale" : "cached"
            )
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.refreshPermissionState()
                if isStale {
                    await self?.reconcileStaleOpenItems()
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.cycle(forward: forward)
        }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isVisible else {
            return false
        }

        switch Int(event.keyCode) {
        case Int(kVK_RightArrow) where event.modifierFlags.contains(.option):
            snapSelected(to: .right)
            return true
        case Int(kVK_LeftArrow) where event.modifierFlags.contains(.option):
            snapSelected(to: .left)
            return true
        case Int(kVK_UpArrow) where event.modifierFlags.contains(.option):
            snapSelected(to: .top)
            return true
        case Int(kVK_DownArrow) where event.modifierFlags.contains(.option):
            snapSelected(to: .bottom)
            return true
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
        case Int(kVK_ANSI_Comma) where event.modifierFlags.contains(.command):
            openSettings()
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

    func snap(_ item: WindowItem, to edge: WindowSnapEdge) {
        selectedID = item.id
        performSelectionAction(for: item) { activator, selectedItem in
            _ = activator.snap(selectedItem, to: edge)
        }
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
        if isSwitching, !isVisible {
            commitWhenOpenCompletes = true
            return
        }

        guard let item = selectedItem else {
            cancel()
            return
        }

        performSelectionAction(for: item) { activator, selectedItem in
            activator.activate(selectedItem)
        }
    }

    func cancel() {
        hide()
    }

    func openSettings() {
        hide()
        onOpenSettings?()
    }

    func switchToPreviousApplication() {
        guard SwitchBladeSettings.shared.doubleModifierSwitchEnabled else {
            Logger.switcher.info("Double modifier switch ignored: setting disabled")
            return
        }
        guard !isVisible, !isSwitching else {
            Logger.switcher.info("Double modifier switch ignored: switcher is visible or opening")
            return
        }

        let effectiveCurrentPID = currentAppPID
        guard let targetPID = previousApplicationPID(currentPID: effectiveCurrentPID) else {
            Logger.switcher.info(
                "Double modifier switch ignored: no previous app current=\(effectiveCurrentPID ?? -1, privacy: .public) previous=\(self.previousAppPID ?? -1, privacy: .public)"
            )
            return
        }

        lastSwitcherUse = Date()
        if let effectiveCurrentPID, effectiveCurrentPID != switchBladePID {
            previousAppPID = effectiveCurrentPID
        }
        currentAppPID = targetPID
        Logger.switcher.info(
            "Double modifier switching app current=\(effectiveCurrentPID ?? -1, privacy: .public) target=\(targetPID, privacy: .public)"
        )
        activator.activateApplication(pid: targetPID)
    }

    private func previousApplicationPID(currentPID: pid_t?) -> pid_t? {
        if let previousAppPID,
           previousAppPID != switchBladePID,
           previousAppPID != currentPID {
            return previousAppPID
        }

        return catalog.snapshotVisibleOnly().first { item in
            item.pid != switchBladePID && item.pid != currentPID
        }?.pid
    }

    private func snapSelected(to edge: WindowSnapEdge) {
        guard let item = selectedItem else {
            cancel()
            return
        }

        snap(item, to: edge)
    }

    private var selectedItem: WindowItem? {
        items.first(where: { $0.id == selectedID })
    }

    private func performSelectionAction(
        for item: WindowItem,
        action: @escaping (WindowActivating, WindowItem) -> Void
    ) {
        mruTracker.rememberSelection(item.id, in: items)
        hide()
        // Give AppKit one frame to commit orderOut before WindowActivator starts
        // synchronous AX IPC to the target app.
        let activator = self.activator
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            action(activator, item)
        }
    }

    private func hydratedForDisplay(_ sourceItems: [WindowItem]) -> [WindowItem] {
        guard SwitchBladeSettings.shared.previewMode != .iconsOnly else {
            return sourceItems
        }
        return sourceItems.map(previewCache.hydrated)
    }

    private func orderItems(_ sourceItems: [WindowItem]) -> [WindowItem] {
        guard let first = sourceItems.first else { return [] }
        let rest = Array(sourceItems.dropFirst())

        switch SwitchBladeSettings.shared.sortOrder {
        case .recentlyUsed:
            return sourceItems
        case .appGrouped:
            return [first] + rest.sorted {
                if $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedSame {
                    return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
                }
                return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
        case .alphabetical:
            return [first] + rest.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        }
    }

    private func hide() {
        previewGeneration += 1
        previewLoadTask?.cancel()
        previewLoadTask = nil
        openItemsWarmupTask?.cancel()
        previewWarmupTask?.cancel()
        isVisible = false
        isSwitching = false
        hoverEnabled = false
        commitWhenOpenCompletes = false
        pendingOpenRequestedAt = nil
        onHide?()
        scheduleContentCacheWarmup(delayNanoseconds: 250_000_000)
        scheduleOpenItemsCacheWarmup(context: "after hide", delayNanoseconds: 250_000_000)
    }

    private func openFromOrderedItems(
        _ orderedItems: [WindowItem],
        openStart: Date,
        queueMs: Double?,
        permissionMs: Double,
        snapshotMs: Double,
        orderMs: Double,
        source: String
    ) {
        guard !orderedItems.isEmpty else {
            isSwitching = false
            commitWhenOpenCompletes = false
            Logger.switcher.notice("Cycle aborted: snapshot is empty")
            return
        }

        updateCachedOpenItems(orderedItems)
        let hydrateStart = Date()
        items = hydratedForDisplay(orderedItems)
        let hydrateMs = Date().timeIntervalSince(hydrateStart) * 1000
        // Preselect the second item so a tap-Cmd+Tab+release toggles between
        // the two most-recent windows. With only one item, select that.
        selectedID = items.indices.contains(1) ? items[1].id : items.first?.id

        let cachedHits = items.filter { $0.preview != nil }.count
        let coldMs = Date().timeIntervalSince(openStart) * 1000
        let coldSummary = performanceMetrics.recordColdOpen(milliseconds: coldMs)
        if PerformanceLoggingState.mode != .off {
            if let queueMs {
                Logger.switcher.info(
                    "Cold-open: \(orderedItems.count, privacy: .public) windows in \(coldMs, format: .fixed(precision: 1), privacy: .public) ms, \(cachedHits, privacy: .public) from cache; source=\(source, privacy: .public), queue=\(queueMs, format: .fixed(precision: 1), privacy: .public), permission=\(permissionMs, format: .fixed(precision: 1), privacy: .public), snapshot=\(snapshotMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public), hydrate=\(hydrateMs, format: .fixed(precision: 1), privacy: .public); rolling n=\(coldSummary.count, privacy: .public), avg=\(coldSummary.average, format: .fixed(precision: 1), privacy: .public), p95=\(coldSummary.p95, format: .fixed(precision: 1), privacy: .public), p99=\(coldSummary.p99, format: .fixed(precision: 1), privacy: .public), max=\(coldSummary.max, format: .fixed(precision: 1), privacy: .public)"
                )
            } else {
                Logger.switcher.info(
                    "Cold-open: \(orderedItems.count, privacy: .public) windows in \(coldMs, format: .fixed(precision: 1), privacy: .public) ms, \(cachedHits, privacy: .public) from cache; source=\(source, privacy: .public), queue=n/a, permission=\(permissionMs, format: .fixed(precision: 1), privacy: .public), snapshot=\(snapshotMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public), hydrate=\(hydrateMs, format: .fixed(precision: 1), privacy: .public); rolling n=\(coldSummary.count, privacy: .public), avg=\(coldSummary.average, format: .fixed(precision: 1), privacy: .public), p95=\(coldSummary.p95, format: .fixed(precision: 1), privacy: .public), p99=\(coldSummary.p99, format: .fixed(precision: 1), privacy: .public), max=\(coldSummary.max, format: .fixed(precision: 1), privacy: .public)"
                )
            }
        }
        showWithPreviews()

        if commitWhenOpenCompletes {
            // Clear before the delegate call — commitSelection() must not
            // re-enter this branch if it somehow triggers another cycle.
            commitWhenOpenCompletes = false
            commitSelection()
            return
        }

        // Lazily fetch minimized windows off the main thread and merge them in.
        // The AX walk is ~150–500ms with many apps — running it here would block
        // the panel from appearing.
        let mergeGeneration = previewGeneration
        let catalog = self.catalog
        Task.detached(priority: .userInitiated) { [weak self] in
            let minimized = await catalog.snapshotMinimized()
            await self?.mergeMinimizedItems(minimized, generation: mergeGeneration)
        }
    }

    func schedulePreviewCacheWarmup(context: String) {
        previewWarmupTask?.cancel()
        previewWarmupTask = Task { @MainActor [weak self] in
            await self?.warmPreviewCache(context: context)
        }
    }

    func scheduleOpenItemsCacheWarmup(context: String) {
        scheduleOpenItemsCacheWarmup(context: context, delayNanoseconds: 0)
    }

    private func scheduleContentCacheWarmup(delayNanoseconds: UInt64) {
        contentCacheWarmupTask?.cancel()
        let catalog = self.catalog
        contentCacheWarmupTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let self, !Task.isCancelled, !self.isVisible, !self.isSwitching else { return }
            await catalog.refreshContentCacheIfStale()
        }
    }

    private func scheduleOpenItemsCacheWarmup(context: String, delayNanoseconds: UInt64) {
        openItemsWarmupTask?.cancel()
        openItemsWarmupTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let self, !Task.isCancelled, !self.isVisible, !self.isSwitching else { return }

            let start = Date()
            let visibleSnapshot = await self.snapshotVisibleOnlyOffMain()
            guard !Task.isCancelled, !self.isVisible, !self.isSwitching else { return }
            let orderedItems = self.orderItems(self.mruTracker.orderedForDisplay(from: visibleSnapshot))
            guard !Task.isCancelled, !orderedItems.isEmpty else { return }
            self.updateCachedOpenItems(orderedItems)
            let ms = Date().timeIntervalSince(start) * 1000
            if PerformanceLoggingState.mode != .off {
                Logger.switcher.info(
                    "Open-items cache warmup (\(context, privacy: .public)): \(orderedItems.count, privacy: .public) windows in \(ms, format: .fixed(precision: 1), privacy: .public) ms"
                )
            }
        }
    }

    private func updateCachedOpenItems(_ orderedItems: [WindowItem]) {
        cachedOpenItems = orderedItems
        cachedOpenItemsUpdatedAt = orderedItems.isEmpty ? nil : Date()
    }

    private func isCachedOpenItemsFresh(now: Date = Date()) -> Bool {
        guard let updatedAt = cachedOpenItemsUpdatedAt else { return false }
        return now.timeIntervalSince(updatedAt) <= cachedOpenItemsMaxAge
    }

    private func snapshotVisibleOnlyOffMain() async -> [WindowItem] {
        let catalog = self.catalog
        return await Task.detached(priority: .utility) {
            catalog.snapshotVisibleOnly()
        }.value
    }

    private func reconcileStaleOpenItems() async {
        guard isVisible else { return }
        let freshSnapshot = await snapshotVisibleOnlyOffMain()
        guard isVisible else { return }
        let freshOrdered = orderItems(mruTracker.orderedForDisplay(from: freshSnapshot))
        updateCachedOpenItems(freshOrdered)
        let freshIDs = Set(freshOrdered.map(\.id))
        let currentIDs = Set(items.map(\.id))
        let newItems = freshOrdered
            .filter { !currentIDs.contains($0.id) }
            .map(previewCache.hydrated)
        // Bulk replace: keep surviving items in display order, append new ones.
        // Avoids calling removeItem(withID:) per-item, which would invoke cancel()
        // prematurely if all stale items happen to be gone from the fresh snapshot.
        items = items.filter { freshIDs.contains($0.id) } + newItems
        mruTracker.pruneToLive(items)
        if items.isEmpty {
            cancel()
            return
        }
        if !items.contains(where: { $0.id == selectedID }) {
            selectedID = items.first?.id
        }
    }

    private func showWithPreviews() {
        guard SwitchBladeSettings.shared.previewMode != .iconsOnly else {
            previewGeneration += 1
            let generation = previewGeneration
            hoverEnabled = false
            isVisible = true
            schedulePanelShow(generation: generation)
            scheduleHoverEnable(generation: previewGeneration)
            return
        }

        let windowIDs = items.filter { !$0.isMinimized && $0.canCapturePreview }.map(\.windowID)

        previewGeneration += 1
        let generation = previewGeneration

        guard !windowIDs.isEmpty else {
            hoverEnabled = false
            isVisible = true
            schedulePanelShow(generation: generation)
            scheduleHoverEnable(generation: generation)
            return
        }

        let initialWindowIDs = Array(windowIDs.prefix(10))
        var priorityWindowIDs: [CGWindowID] = []
        if let selectedID, initialWindowIDs.contains(selectedID) {
            priorityWindowIDs.append(selectedID)
        }
        if let frontmostID = initialWindowIDs.first,
           !priorityWindowIDs.contains(frontmostID) {
            priorityWindowIDs.append(frontmostID)
        }
        let remainingInitialWindowIDs = initialWindowIDs.filter { !priorityWindowIDs.contains($0) }
        let catalog = self.catalog

        hoverEnabled = false
        isVisible = true
        schedulePanelShow(generation: generation)
        scheduleHoverEnable(generation: generation)

        previewLoadTask = Task {
            let batchStart = Date()
            var previews: [CGWindowID: NSImage] = [:]
            let firstBatchWindowIDs = priorityWindowIDs + remainingInitialWindowIDs
            if !firstBatchWindowIDs.isEmpty {
                let batchPreviews = await catalog.capturePreviews(
                    for: firstBatchWindowIDs,
                    maxCount: nil,
                    maxConcurrentCaptures: min(4, firstBatchWindowIDs.count)
                )
                guard !Task.isCancelled else { return }
                previews.merge(batchPreviews) { _, fresh in fresh }
                self.applyPreviews(batchPreviews, generation: generation)
            }

            guard !Task.isCancelled else { return }
            let firstBatchMs = Date().timeIntervalSince(batchStart) * 1000
            let successRate = windowIDs.isEmpty ? 0
                : Double(previews.count) / Double(initialWindowIDs.count)
            let batchSummary = self.performanceMetrics.recordFirstPreviewBatch(milliseconds: firstBatchMs)
            if PerformanceLoggingState.mode != .off {
                Logger.switcher.info(
                    "First preview batch: \(previews.count, privacy: .public)/\(initialWindowIDs.count, privacy: .public) in \(firstBatchMs, format: .fixed(precision: 1), privacy: .public) ms (rate \(successRate, format: .fixed(precision: 2), privacy: .public)); rolling n=\(batchSummary.count, privacy: .public), avg=\(batchSummary.average, format: .fixed(precision: 1), privacy: .public), p95=\(batchSummary.p95, format: .fixed(precision: 1), privacy: .public), p99=\(batchSummary.p99, format: .fixed(precision: 1), privacy: .public), max=\(batchSummary.max, format: .fixed(precision: 1), privacy: .public)"
                )
            }

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

            // Refresh SC content cache after a full preview pass. Fast
            // Cmd+Tab+release is covered by the hide/app-activation warmup path.
            Task.detached(priority: .utility) { [catalog] in
                await catalog.refreshContentCache()
            }
        }
    }

    private func applyPreviews(_ previews: [CGWindowID: NSImage], generation: Int) {
        guard isVisible, previewGeneration == generation else { return }
        let acceptedPreviews = previewCache.record(previews, liveItems: items)
        items = items.map { item in
            acceptedPreviews[item.windowID].map { item.withPreview($0) } ?? item
        }
    }

    private func mergeMinimizedItems(_ minimized: [WindowItem], generation: Int) {
        guard isVisible, previewGeneration == generation, !minimized.isEmpty else { return }
        let existingIDs = Set(items.map(\.id))
        let newItems = minimized
            .filter { !existingIDs.contains($0.id) }
            .map { item in
                SwitchBladeSettings.shared.previewMode == .iconsOnly ? item : previewCache.hydrated(item)
            }
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

    private func schedulePanelShow(generation: Int) {
        guard isVisible, previewGeneration == generation else { return }
        onShow?()
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
