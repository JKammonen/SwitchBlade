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
    /// Derived from `phase` (anything but `.idle`); kept as public surface for
    /// `AppDelegate`'s modifier-release tracking and the test suite.
    var isSwitching: Bool { phase != .idle }

    /// Single source of truth for the open lifecycle. Folded in the formerly
    /// interacting booleans `hasPreparedHiddenOpen` / `commitWhenOpenCompletes` /
    /// `isShowingStaleCachedItems`. `isSwitching` is derived from this (above) and
    /// `isVisible` is mirrored into a `@Published` (below) for surface stability.
    private enum OpenPhase: Equatable {
        case idle                                  // not switching, not visible
        case resolving(commitWhenReady: Bool)      // off-main items resolution in flight
        case previewHidden(showingStale: Bool)     // items resolved, panel deferred for fast release
        case visible(showingStale: Bool)           // panel on screen
    }

    private var phase: OpenPhase = .idle {
        didSet {
            let nowVisible: Bool
            if case .visible = phase { nowVisible = true } else { nowVisible = false }
            if isVisible != nowVisible { isVisible = nowVisible }
        }
    }

    private let catalog: WindowSnapshotProviding
    private let activator: WindowActivating
    private let permissionService: PermissionProviding
    private let previewCache: PreviewCacheStore
    private let mruTracker: MRUTracker
    private let performanceMetrics: SwitcherPerformanceMetrics
    private let switchBladePID: pid_t

    private var previewLoadTask: Task<Void, Never>?
    private var openRefreshTask: Task<Void, Never>?
    private var staleCacheHealTask: Task<Void, Never>?
    private var contentCacheWarmupTask: Task<Void, Never>?
    private var openItemsWarmupTask: Task<Void, Never>?
    private var panelShowTask: Task<Void, Never>?
    private var previewWarmupTask: Task<Void, Never>?
    private var inFlightVisibleSnapshot: InFlightVisibleSnapshot?
    private var previewGeneration = 0
    private var pendingOpenRequestedAt: Date?
    private var activeOpenRequestedAt: Date?
    private var currentOpenSource: String?
    private var cachedOpenItems: [WindowItem] = []
    private var cachedOpenItemsUpdatedAt: Date?
    /// Set when app focus changes outside the switcher after the cache was
    /// built. The cached list may still be young by timestamp, but its first
    /// item can now point at the wrong frontmost app for a fast Cmd+Tab.
    private var cachedOpenItemsNeedResnapshot = false
    nonisolated(unsafe) private var activationObserver: Any?
    /// Prevents the tile under the mouse from stealing selection when the panel first appears.
    private var hoverEnabled = false
    private var currentAppPID: pid_t?
    private var previousAppPID: pid_t?
    /// True while a previous-app switch is resolving its off-main snapshot.
    /// Serializes the gesture so a second rapid double-tap can't run against the
    /// PID the first one is about to mutate.
    private var isResolvingPreviousSwitch = false

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
    private let initialPanelShowDelayNanoseconds: UInt64
    private let deferredPreviewCaptureBudget: Int

    private final class InFlightVisibleSnapshot {
        let task: Task<[WindowItem], Never>

        init(task: Task<[WindowItem], Never>) {
            self.task = task
        }
    }

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
        initialPanelShowDelayNanoseconds: UInt64 = 0,
        deferredPreviewCaptureBudget: Int = 12,
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
        self.initialPanelShowDelayNanoseconds = initialPanelShowDelayNanoseconds
        self.deferredPreviewCaptureBudget = max(0, deferredPreviewCaptureBudget)
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
                cachedOpenItemsNeedResnapshot = true
            }
            let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            mruTracker.trackSystemActivation(pid, in: items, bundleIdentifier: bundleIdentifier)
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
        openRefreshTask?.cancel()
        panelShowTask?.cancel()
        staleCacheHealTask?.cancel()
        previewWarmupTask?.cancel()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func refreshPermissionState() {
        permissionState = permissionService.currentState()
    }

    func invalidateCaptureCache(reason: String) async {
        await catalog.invalidateContentCache(reason: reason)
    }

    func warmPreviewCache(context: String) async {
        guard SwitchBladeSettings.shared.previewMode != .iconsOnly else { return }
        guard !isVisible, !isSwitching else { return }

        let visibleSnapshot = await snapshotVisibleOnlyOffMain()
        guard !Task.isCancelled, !isVisible, !isSwitching else { return }
        let orderedItems = orderItems(mruTracker.orderedForDisplay(from: visibleSnapshot, context: "warm-preview"))
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
        let whiteIDs = await PreviewCacheStore.mostlyWhiteWindowIDs(in: previews)
        guard !Task.isCancelled, !isVisible, !isSwitching else { return }
        let acceptedPreviews = previewCache.record(previews, liveItems: orderedItems, mostlyWhiteIDs: whiteIDs)
        let ms = Date().timeIntervalSince(start) * 1000
        Logger.switcher.info(
            "Preview cache warmup (\(context, privacy: .public)): \(acceptedPreviews.count, privacy: .public)/\(initialWindowIDs.count, privacy: .public) in \(ms, format: .fixed(precision: 1), privacy: .public) ms"
        )
    }

    /// Moves the selection while the panel is visible. The cold-open path lives
    /// in `requestCycle`; `requestCycle` only calls this once `isVisible` is true,
    /// so there is no synchronous-open branch here anymore.
    func cycle(forward: Bool) {
        Logger.switcher.notice("cycle: enter isVisible=\(self.isVisible, privacy: .public)")
        // Mark "the user is using the switcher right now" so handleAppActivation
        // knows it's worth warming the SCKit cache on app switches for the next
        // ~minute. Idle users (haven't pressed Cmd+Tab in a while) skip the warmup.
        lastSwitcherUse = Date()
        contentCacheWarmupTask?.cancel()
        openItemsWarmupTask?.cancel()
        previewWarmupTask?.cancel()
        permissionState = permissionService.currentState()

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
        if case .previewHidden = phase {
            moveSelection(forward ? 1 : -1)
            return
        }
        // Two rapid Cmd+Tab events arrive before the async open completes: we are
        // already switching but not yet visible or in the previewHidden phase. The
        // second call would start a second open and double-fire the preview load.
        // Drop it — the in-flight open (openFromFreshSnapshotOffMain, or the cached
        // openFromOrderedItems path) already covers this key-down.
        guard !isSwitching else { return }

        lastSwitcherUse = Date()
        contentCacheWarmupTask?.cancel()
        openItemsWarmupTask?.cancel()
        openRefreshTask?.cancel()
        panelShowTask?.cancel()
        previewWarmupTask?.cancel()
        pendingOpenRequestedAt = Date()
        activeOpenRequestedAt = pendingOpenRequestedAt
        enterResolving(commitWhenReady: false)

        if !cachedOpenItems.isEmpty {
            if cachedOpenItemsNeedResnapshot {
                if let rebasedItems = rebasedCachedOpenItemsForCurrentApp() {
                    Logger.switcher.info(
                        "Using rebased cached open items after external activation"
                    )
                    let openStart = Date()
                    let queueMs = pendingOpenRequestedAt.map { openStart.timeIntervalSince($0) * 1000 } ?? 0
                    pendingOpenRequestedAt = nil
                    openFromOrderedItems(
                        rebasedItems,
                        openStart: openStart,
                        queueMs: queueMs,
                        permissionMs: 0,
                        snapshotMs: 0,
                        orderMs: 0,
                        source: "rebased-cached",
                        updateCachedItems: false,
                        showingStaleCachedItems: true
                    )
                    scheduleStaleCacheHealingIfNeeded()
                    Task { @MainActor [weak self] in
                        await Task.yield()
                        self?.refreshPermissionState()
                    }
                    return
                }
                Logger.switcher.info(
                    "Bypassing cached open items after external activation changed the frontmost app"
                )
                openFromFreshSnapshotOffMain()
                return
            }
            let cacheIsFresh = isCachedOpenItemsFresh()
            let openStart = Date()
            let queueMs = pendingOpenRequestedAt.map { openStart.timeIntervalSince($0) * 1000 } ?? 0
            pendingOpenRequestedAt = nil
            openFromOrderedItems(
                cachedOpenItems,
                openStart: openStart,
                queueMs: queueMs,
                permissionMs: 0,
                snapshotMs: 0,
                orderMs: 0,
                source: cacheIsFresh ? "cached" : "stale-cached",
                updateCachedItems: cacheIsFresh,
                showingStaleCachedItems: !cacheIsFresh
            )
            if !cacheIsFresh {
                scheduleStaleCacheHealingIfNeeded()
            }
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.refreshPermissionState()
            }
            return
        }

        openFromFreshSnapshotOffMain()
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
        Logger.switcher.info(
            "Choose item id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public)"
        )
        selectedID = item.id
        commitSelection()
    }

    func snap(_ item: WindowItem, to edge: WindowSnapEdge) {
        selectedID = item.id
        performSelectionAction(for: item, actionName: "snap-\(edge.rawValue)") { activator, selectedItem in
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
        mruTracker.dropAllRanks(
            forAppIdentity: selected.bundleIdentifier ?? selected.appName,
            bundleIdentifier: selected.bundleIdentifier
        )
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
            if case .previewHidden = phase, let item = selectedItem {
                if hiddenStaleCommitNeedsFreshSnapshot(for: item) {
                    deferHiddenStaleCommitUntilFreshSnapshot(item)
                    return
                }
                Logger.switcher.info(
                    "Commit selection from prepared hidden open item id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public)"
                )
                performSelectionAction(for: item, actionName: "activate") { activator, selectedItem in
                    activator.activate(selectedItem)
                }
                return
            }
            Logger.switcher.info("Commit selection deferred until open completes")
            setCommitWhenReady()
            return
        }

        guard let item = selectedItem else {
            Logger.switcher.info("Commit selection cancelled: no selected item")
            cancel()
            return
        }

        Logger.switcher.info(
            "Commit selection item id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public) isVisible=\(self.isVisible, privacy: .public) isSwitching=\(self.isSwitching, privacy: .public)"
        )
        performSelectionAction(for: item, actionName: "activate") { activator, selectedItem in
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

    func handleModifierMouseSwitch() {
        guard SwitchBladeSettings.shared.doubleModifierSwitchEnabled else {
            Logger.switcher.info("Modifier mouse switch ignored: setting disabled")
            return
        }

        guard !isVisible, !isSwitching else {
            Logger.switcher.info("Modifier mouse switch committing current selection")
            commitSelection()
            return
        }

        switchToPreviousApplication()
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
        // Drop a second gesture that arrives while the first is still resolving
        // its off-main snapshot. The switch path doesn't set isVisible/isSwitching,
        // so without this guard two rapid double-taps would both run and the
        // second would read the currentAppPID the first just mutated — an extra,
        // unintended switch. The synchronous predecessor couldn't interleave.
        guard !isResolvingPreviousSwitch else {
            Logger.switcher.info("Double modifier switch ignored: previous-app switch already resolving")
            return
        }

        if let targetPID = fastPreviousApplicationPIDFromCache() {
            performFastPreviousApplicationSwitch(targetPID: targetPID)
            return
        }

        // Enumerate windows off the main thread. The previous-app switch is a
        // user-facing gesture (double-tap modifier / modifier+click); doing the
        // CGWindowList walk + NSRunningApplication lookups + icon copies inline
        // on @MainActor hitched the gesture with many windows open. Every other
        // open path already snapshots off-main — this one was the holdout.
        isResolvingPreviousSwitch = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isResolvingPreviousSwitch = false }
            let orderedItems = await self.itemsForPreviousSwitchTarget()
            guard !self.isVisible, !self.isSwitching else {
                Logger.switcher.info("Double modifier switch aborted: switcher opened during snapshot")
                return
            }
            self.performPreviousApplicationSwitch(orderedItems: orderedItems)
        }
    }

    private func performPreviousApplicationSwitch(orderedItems: [WindowItem]) {
        let effectiveCurrentPID = orderedItems.first?.pid ?? currentAppPID
        if let targetItem = previousSwitchTarget(from: orderedItems, currentPID: effectiveCurrentPID) {
            lastSwitcherUse = Date()
            mruTracker.rememberSelection(targetItem.id, in: orderedItems, context: "double-modifier-window")
            if let effectiveCurrentPID, effectiveCurrentPID != switchBladePID, effectiveCurrentPID != targetItem.pid {
                previousAppPID = effectiveCurrentPID
            }
            currentAppPID = targetItem.pid
            Logger.switcher.info(
                "Double modifier switching window current=\(effectiveCurrentPID ?? -1, privacy: .public) targetWindow=\(targetItem.id, privacy: .public) targetPID=\(targetItem.pid, privacy: .public)"
            )
            activator.activate(targetItem)
            return
        }

        guard let targetPID = previousApplicationPID(currentPID: effectiveCurrentPID, orderedItems: orderedItems) else {
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

    private func performFastPreviousApplicationSwitch(targetPID: pid_t) {
        guard let effectiveCurrentPID = currentAppPID else { return }
        lastSwitcherUse = Date()
        previousAppPID = effectiveCurrentPID
        currentAppPID = targetPID
        Logger.switcher.info(
            "Fast previous-app switch current=\(effectiveCurrentPID, privacy: .public) target=\(targetPID, privacy: .public)"
        )
        activator.activateApplication(pid: targetPID)
    }

    private func previousSwitchTarget(from orderedItems: [WindowItem], currentPID: pid_t?) -> WindowItem? {
        guard orderedItems.count > 1 else { return nil }

        guard let effectiveCurrentPID = currentPID else { return nil }
        let candidate = orderedItems[1]
        guard candidate.pid == effectiveCurrentPID, candidate.pid != switchBladePID else { return nil }
        return candidate
    }

    private func itemsForPreviousSwitchTarget() async -> [WindowItem] {
        let snapshot = await snapshotVisibleOnlyOffMain(priority: .userInitiated)
        return mruTracker.orderedForDisplay(from: snapshot, context: "previous-switch-target")
    }

    private func previousApplicationPID(currentPID: pid_t?, orderedItems: [WindowItem]) -> pid_t? {
        if let previousAppPID,
           previousAppPID != switchBladePID,
           previousAppPID != currentPID {
            return previousAppPID
        }

        return orderedItems.first { item in
            item.pid != switchBladePID && item.pid != currentPID
        }?.pid
    }

    private func fastPreviousApplicationPIDFromCache() -> pid_t? {
        guard let currentAppPID,
              let previousAppPID,
              previousAppPID != switchBladePID,
              previousAppPID != currentAppPID,
              isCachedOpenItemsFresh() else {
            return nil
        }

        let currentAppWindowCount = cachedOpenItems.reduce(0) { count, item in
            count + (item.pid == currentAppPID ? 1 : 0)
        }
        guard currentAppWindowCount == 1 else { return nil }

        return previousAppPID
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
        liveItems: [WindowItem]? = nil,
        actionName: String,
        source: String? = nil,
        action: @escaping (WindowActivating, WindowItem) -> Void
    ) {
        let liveItems = liveItems ?? items
        let actionSource = source ?? currentOpenSource ?? "unknown"
        Logger.switcher.info(
            "Schedule selection action=\(actionName, privacy: .public) source=\(actionSource, privacy: .public) item id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public)"
        )
        mruTracker.rememberSelection(
            item.id,
            in: liveItems,
            context: "selection-\(actionName)-source=\(actionSource)-stale=\(currentShowingStale)"
        )
        let scheduledAt = Date()
        hide()
        // Give AppKit one frame to commit orderOut before WindowActivator starts
        // synchronous AX IPC to the target app.
        let activator = self.activator
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            let dispatchDelayMs = Date().timeIntervalSince(scheduledAt) * 1000
            PerformanceDiagnostics.record(
                "selection_action_dispatch",
                fields: [
                    "action": .string(actionName),
                    "dispatch_delay_ms": .double(dispatchDelayMs),
                    "pid": .int(Int(item.pid)),
                    "source": .string(actionSource),
                    "window_id": .int(Int(item.id))
                ]
            )
            Logger.switcher.info(
                "Dispatch selection action=\(actionName, privacy: .public) source=\(actionSource, privacy: .public) item id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public) delay=\(dispatchDelayMs, format: .fixed(precision: 1), privacy: .public)ms"
            )
            action(activator, item)
        }
    }

    private func hydratedForDisplay(_ sourceItems: [WindowItem]) -> [WindowItem] {
        guard SwitchBladeSettings.shared.previewMode != .iconsOnly else {
            return sourceItems
        }
        return sourceItems.map { previewCache.hydrated($0, liveItems: sourceItems) }
    }

    private func defaultSelectedID(in orderedItems: [WindowItem]) -> WindowItem.ID? {
        orderedItems.indices.contains(1) ? orderedItems[1].id : orderedItems.first?.id
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

    // MARK: - Open-phase mutators
    //
    // `phase` is the single source of truth for the open lifecycle. Every
    // transition routes through one of these so the lifecycle reads as a state
    // machine, not a soup of interacting flags. `isVisible` is mirrored from
    // `phase` in its didSet; `isSwitching` is derived (`phase != .idle`).

    private func enterIdle() {
        phase = .idle
    }

    private func enterResolving(commitWhenReady: Bool) {
        phase = .resolving(commitWhenReady: commitWhenReady)
    }

    private func setCommitWhenReady() {
        guard case .resolving = phase else { return }
        phase = .resolving(commitWhenReady: true)
    }

    private func enterPreviewHidden(stale: Bool) {
        phase = .previewHidden(showingStale: stale)
    }

    private func enterVisible(stale: Bool) {
        phase = .visible(showingStale: stale) // didSet mirrors isVisible = true
    }

    private func setShowingStale(_ stale: Bool) {
        switch phase {
        case .previewHidden:
            phase = .previewHidden(showingStale: stale)
        case .visible:
            phase = .visible(showingStale: stale)
        case .idle, .resolving:
            break
        }
    }

    /// Stale flag carried by the current display phase (false while idle/resolving).
    private var currentShowingStale: Bool {
        switch phase {
        case .previewHidden(let stale), .visible(let stale):
            return stale
        case .idle, .resolving:
            return false
        }
    }

    private func hide() {
        previewGeneration += 1
        previewLoadTask?.cancel()
        previewLoadTask = nil
        openItemsWarmupTask?.cancel()
        openRefreshTask?.cancel()
        panelShowTask?.cancel()
        panelShowTask = nil
        previewWarmupTask?.cancel()
        enterIdle()
        hoverEnabled = false
        pendingOpenRequestedAt = nil
        activeOpenRequestedAt = nil
        currentOpenSource = nil
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
        source: String,
        updateCachedItems: Bool = true,
        showingStaleCachedItems: Bool = false
    ) {
        guard !orderedItems.isEmpty else {
            enterIdle()
            Logger.switcher.notice("Cycle aborted: snapshot is empty")
            return
        }

        currentOpenSource = source
        if updateCachedItems {
            updateCachedOpenItems(orderedItems)
        }
        // Display staleness is carried into the visible/previewHidden phase by the
        // mutators at the end of this method (enterPreviewHidden / enterVisible).
        let preselectedID = defaultSelectedID(in: orderedItems)

        // Quick Cmd+Tab release should not pay the panel show or preview path
        // once the target window has already been resolved off-main.
        if case .resolving(let commitWhenReady) = phase, commitWhenReady {
            logOpenOrdering(source: "\(source)-quick-release", orderedItems: orderedItems, selectedID: preselectedID)
            let quickSwitchMs = Date().timeIntervalSince(openStart) * 1000
            if PerformanceLoggingState.mode != .off {
                if let queueMs {
                    Logger.switcher.info(
                        "Quick release before panel show: \(orderedItems.count, privacy: .public) windows ready in \(quickSwitchMs, format: .fixed(precision: 1), privacy: .public) ms; source=\(source, privacy: .public), queue=\(queueMs, format: .fixed(precision: 1), privacy: .public), permission=\(permissionMs, format: .fixed(precision: 1), privacy: .public), snapshot=\(snapshotMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public)"
                    )
                } else {
                    Logger.switcher.info(
                        "Quick release before panel show: \(orderedItems.count, privacy: .public) windows ready in \(quickSwitchMs, format: .fixed(precision: 1), privacy: .public) ms; source=\(source, privacy: .public), queue=n/a, permission=\(permissionMs, format: .fixed(precision: 1), privacy: .public), snapshot=\(snapshotMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public)"
                    )
                }
            }

            // commitWhenReady is cleared by the hide() → enterIdle() that follows
            // this activation (or the guard-fail hide() below).
            guard let preselectedID,
                  let item = orderedItems.first(where: { $0.id == preselectedID }) else {
                Logger.switcher.notice("Quick release aborted: no selected item after snapshot")
                hide()
                return
            }

            performSelectionAction(
                for: item,
                liveItems: orderedItems,
                actionName: "activate",
                source: source
            ) { activator, selectedItem in
                activator.activate(selectedItem)
            }
            return
        }

        let hydrateStart = Date()
        let hydratedItems = hydratedForDisplay(orderedItems)
        let hydrateMs = Date().timeIntervalSince(hydrateStart) * 1000
        // Preselect the second item so a tap-Cmd+Tab+release toggles between
        // the two most-recent windows. With only one item, select that.
        // Disable animations so tiles appear at their final positions instantly
        // on open — sliding/scaling on open is distracting; animation is reserved
        // for explicit Tab/arrow navigation while the panel is already visible.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            items = hydratedItems
            selectedID = preselectedID
        }
        logOpenOrdering(source: source, orderedItems: orderedItems, selectedID: selectedID)

        let cachedHits = items.filter { $0.preview != nil }.count
        let coldMs = Date().timeIntervalSince(openStart) * 1000
        let coldSummary = performanceMetrics.recordColdOpen(milliseconds: coldMs)
        var coldFields: [String: PerformanceMetricValue] = [
            "cached_hits": .int(cachedHits),
            "hydrate_ms": .double(hydrateMs),
            "milliseconds": .double(coldMs),
            "order_ms": .double(orderMs),
            "permission_ms": .double(permissionMs),
            "source": .string(source),
            "window_count": .int(orderedItems.count)
        ]
        if let queueMs {
            coldFields["queue_ms"] = .double(queueMs)
        }
        coldFields["snapshot_ms"] = .double(snapshotMs)
        PerformanceDiagnostics.record("cold_open", fields: coldFields)
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
        enterPreviewHidden(stale: showingStaleCachedItems)
        schedulePreparedPanelShow()
        // Minimized merge is now scheduled inside showWithPreviews so it
        // captures the post-increment previewGeneration. Capturing here would
        // race the delay-path: schedulePreparedPanelShow defers showWithPreviews
        // by initialPanelShowDelayNanoseconds, so previewGeneration would
        // still be the pre-show value, and the eventual merge-guard
        // `previewGeneration == generation` would always fail.
    }

    private func openFromFreshSnapshotOffMain() {
        openRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let permissionStart = Date()
            self.permissionState = self.permissionService.currentState()
            let permissionMs = Date().timeIntervalSince(permissionStart) * 1000

            let openStart = Date()
            let queueMs = self.pendingOpenRequestedAt.map { openStart.timeIntervalSince($0) * 1000 } ?? 0
            self.pendingOpenRequestedAt = nil

            let snapshotStart = Date()
            let visibleSnapshot = await self.snapshotVisibleOnlyOffMain(priority: .userInitiated)
            let snapshotMs = Date().timeIntervalSince(snapshotStart) * 1000

            guard !Task.isCancelled, self.isSwitching, !self.isVisible else { return }

            let orderStart = Date()
            let orderedItems = self.orderItems(self.mruTracker.orderedForDisplay(from: visibleSnapshot, context: "request-snapshot"))
            let orderMs = Date().timeIntervalSince(orderStart) * 1000
            self.openFromOrderedItems(
                orderedItems,
                openStart: openStart,
                queueMs: queueMs,
                permissionMs: permissionMs,
                snapshotMs: snapshotMs,
                orderMs: orderMs,
                source: "snapshot"
            )
        }
    }

    private func scheduleStaleCacheHealingIfNeeded() {
        guard staleCacheHealTask == nil else {
            return
        }

        staleCacheHealTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.staleCacheHealTask = nil }

            let snapshotStart = Date()
            let visibleSnapshot = await self.snapshotVisibleOnlyOffMain(priority: .userInitiated)
            let snapshotMs = Date().timeIntervalSince(snapshotStart) * 1000

            guard !Task.isCancelled else { return }

            let orderStart = Date()
            let orderedItems = self.orderItems(self.mruTracker.orderedForDisplay(from: visibleSnapshot, context: "stale-heal"))
            let orderMs = Date().timeIntervalSince(orderStart) * 1000
            guard !orderedItems.isEmpty else { return }

            self.updateCachedOpenItems(orderedItems)

            if self.currentShowingStale {
                let hydrateMs = self.applyStaleCacheRefresh(
                    orderedItems,
                    showAfterRefresh: self.isVisible
                )
                if PerformanceLoggingState.mode != .off {
                    Logger.switcher.info(
                        "Open-items refresh after stale cache: \(orderedItems.count, privacy: .public) windows; snapshot=\(snapshotMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public), hydrate=\(hydrateMs, format: .fixed(precision: 1), privacy: .public)"
                    )
                }
            } else if PerformanceLoggingState.mode != .off {
                Logger.switcher.info(
                    "Open-items cache healed after stale cache: \(orderedItems.count, privacy: .public) windows; snapshot=\(snapshotMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public)"
                )
            }
        }
    }

    private func applyStaleCacheRefresh(
        _ orderedItems: [WindowItem],
        showAfterRefresh: Bool
    ) -> Double {
        setShowingStale(false)
        let previousSelectedID = selectedID
        let hydrateStart = Date()
        let hydratedItems = hydratedForDisplay(orderedItems)
        let hydrateMs = Date().timeIntervalSince(hydrateStart) * 1000

        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            items = hydratedItems
            if let previousSelectedID, hydratedItems.contains(where: { $0.id == previousSelectedID }) {
                selectedID = previousSelectedID
            } else {
                selectedID = hydratedItems.indices.contains(1) ? hydratedItems[1].id : hydratedItems.first?.id
            }
        }

        previewLoadTask?.cancel()
        if showAfterRefresh {
            showWithPreviews()
        }
        return hydrateMs
    }

    private func schedulePreparedPanelShow() {
        panelShowTask?.cancel()
        let delayNanoseconds = initialPanelShowDelayNanoseconds

        guard delayNanoseconds > 0 else {
            showPreparedPanelIfNeeded()
            return
        }

        panelShowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.showPreparedPanelIfNeeded()
        }
    }

    private func showPreparedPanelIfNeeded() {
        guard case .previewHidden = phase else { return }
        panelShowTask?.cancel()
        panelShowTask = nil
        showWithPreviews()
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
            let orderedItems = self.orderItems(
                self.mruTracker.orderedForDisplay(
                    from: visibleSnapshot,
                    context: "open-items-warmup:\(context)"
                )
            )
            guard !Task.isCancelled, !orderedItems.isEmpty else { return }
            let stabilizedItems = self.stabilizeBackgroundWarmupOrder(orderedItems, context: context)
            self.updateCachedOpenItems(stabilizedItems)
            let ms = Date().timeIntervalSince(start) * 1000
            if PerformanceLoggingState.mode != .off {
                Logger.switcher.info(
                    "Open-items cache warmup (\(context, privacy: .public)): \(stabilizedItems.count, privacy: .public) windows in \(ms, format: .fixed(precision: 1), privacy: .public) ms"
                )
            }
        }
    }

    private func stabilizeBackgroundWarmupOrder(_ orderedItems: [WindowItem], context: String) -> [WindowItem] {
        guard let frontmost = orderedItems.first else { return orderedItems }

        let cachedSameAppCount = cachedOpenItems.filter { $0.pid == frontmost.pid }.count
        guard cachedSameAppCount > 1 else { return orderedItems }

        let freshByID = Dictionary(uniqueKeysWithValues: orderedItems.map { ($0.id, $0) })
        var usedIDs: Set<WindowItem.ID> = [frontmost.id]
        var stabilized: [WindowItem] = [frontmost]

        for cachedItem in cachedOpenItems where cachedItem.id != frontmost.id {
            if let fresh = freshByID[cachedItem.id] {
                guard usedIDs.insert(fresh.id).inserted else { continue }
                stabilized.append(fresh)
                continue
            }

            guard cachedItem.pid == frontmost.pid,
                  usedIDs.insert(cachedItem.id).inserted else { continue }
            stabilized.append(cachedItem)
        }

        for item in orderedItems where usedIDs.insert(item.id).inserted {
            stabilized.append(item)
        }

        logWarmupStabilization(context: context, original: orderedItems, stabilized: stabilized)
        return stabilized
    }

    private func logWarmupStabilization(context: String, original: [WindowItem], stabilized: [WindowItem]) {
        guard PerformanceLoggingState.mode == .debug, original != stabilized else { return }

        let originalSummary = original.prefix(16)
            .map { "id=\($0.id),pid=\($0.pid)" }
            .joined(separator: ";")
        let stabilizedSummary = stabilized.prefix(16)
            .map { "id=\($0.id),pid=\($0.pid)" }
            .joined(separator: ";")
        Logger.switcher.debug(
            "Warmup order stabilized context=\(context, privacy: .public) original=[\(originalSummary, privacy: .public)] stabilized=[\(stabilizedSummary, privacy: .public)]"
        )
    }

    private func updateCachedOpenItems(_ orderedItems: [WindowItem]) {
        cachedOpenItems = orderedItems
        cachedOpenItemsUpdatedAt = orderedItems.isEmpty ? nil : Date()
        cachedOpenItemsNeedResnapshot = false
    }

    private func hiddenStaleCommitNeedsFreshSnapshot(for item: WindowItem) -> Bool {
        guard currentShowingStale else { return false }
        return items.filter { $0.pid == item.pid }.count > 1
    }

    private func deferHiddenStaleCommitUntilFreshSnapshot(_ item: WindowItem) {
        Logger.switcher.info(
            "Deferring hidden stale commit for same-app window id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public) until fresh snapshot"
        )
        panelShowTask?.cancel()
        panelShowTask = nil
        staleCacheHealTask?.cancel()
        staleCacheHealTask = nil
        openRefreshTask?.cancel()
        enterResolving(commitWhenReady: true)
        openFromFreshSnapshotOffMain()
    }

    private func logOpenOrdering(source: String, orderedItems: [WindowItem], selectedID: WindowItem.ID?) {
        guard PerformanceLoggingState.mode == .debug else { return }
        let orderSummary = orderedItems.prefix(16)
            .enumerated()
            .map { index, item in
                let selected = item.id == selectedID ? "S" : "-"
                let frontmost = item.isFrontmostApp ? "F" : "-"
                let appIdentity = item.bundleIdentifier ?? item.appName
                return "\(index):id=\(item.id),pid=\(item.pid),app=\(appIdentity),front=\(frontmost),selected=\(selected)"
            }
            .joined(separator: ";")
        Logger.switcher.debug(
            "Open order source=\(source, privacy: .public) count=\(orderedItems.count, privacy: .public) selectedID=\(selectedID ?? 0, privacy: .public) staleVisible=\(self.currentShowingStale, privacy: .public) order=[\(orderSummary, privacy: .public)]"
        )
    }

    private func isCachedOpenItemsFresh(now: Date = Date()) -> Bool {
        guard let updatedAt = cachedOpenItemsUpdatedAt else { return false }
        return now.timeIntervalSince(updatedAt) <= cachedOpenItemsMaxAge
    }

    private func rebasedCachedOpenItemsForCurrentApp() -> [WindowItem]? {
        guard let currentAppPID,
              isCachedOpenItemsFresh() else {
            return nil
        }

        let matchingIndices = cachedOpenItems.indices.filter { cachedOpenItems[$0].pid == currentAppPID }
        guard matchingIndices.count == 1, let currentIndex = matchingIndices.first else { return nil }

        var items = cachedOpenItems.enumerated().map { _, item in
            item.withFrontmostState(item.pid == currentAppPID)
        }
        let currentItem = items.remove(at: currentIndex)
        items.insert(currentItem, at: 0)
        return items
    }

    private func recordPanelVisibleMetric(itemCount: Int) {
        guard let activeOpenRequestedAt else { return }
        let ms = Date().timeIntervalSince(activeOpenRequestedAt) * 1000
        let source = currentOpenSource ?? "unknown"
        PerformanceDiagnostics.record(
            "keydown_to_panel_visible",
            fields: [
                "item_count": .int(itemCount),
                "milliseconds": .double(ms),
                "source": .string(source),
                "stale": .bool(currentShowingStale)
            ]
        )
        if PerformanceLoggingState.mode != .off {
            Logger.switcher.info(
                "Keydown-to-panel-visible: \(ms, format: .fixed(precision: 1), privacy: .public) ms; source=\(source, privacy: .public), items=\(itemCount, privacy: .public), stale=\(self.currentShowingStale, privacy: .public)"
            )
        }
    }

    private func snapshotVisibleOnlyOffMain(
        priority: TaskPriority = .utility
    ) async -> [WindowItem] {
        if let inFlightVisibleSnapshot {
            return await inFlightVisibleSnapshot.task.value
        }

        let catalog = self.catalog
        let inFlightVisibleSnapshot = InFlightVisibleSnapshot(
            task: Task.detached(priority: priority) {
                catalog.snapshotVisibleOnly()
            }
        )
        self.inFlightVisibleSnapshot = inFlightVisibleSnapshot
        let visibleItems = await inFlightVisibleSnapshot.task.value
        if self.inFlightVisibleSnapshot === inFlightVisibleSnapshot {
            self.inFlightVisibleSnapshot = nil
        }
        return visibleItems
    }

    private func showWithPreviews() {
        panelShowTask?.cancel()
        panelShowTask = nil
        // Carry the incoming display staleness (from .previewHidden / .resolving)
        // into the visible phase below.
        let stale = currentShowingStale
        guard SwitchBladeSettings.shared.previewMode != .iconsOnly else {
            previewGeneration += 1
            let generation = previewGeneration
            hoverEnabled = false
            enterVisible(stale: stale)
            schedulePanelShow(generation: generation)
            scheduleHoverEnable(generation: previewGeneration)
            scheduleMinimizedMerge()
            return
        }

        let windowIDs = items.filter { !$0.isMinimized && $0.canCapturePreview }.map(\.windowID)

        previewGeneration += 1
        let generation = previewGeneration

        guard !windowIDs.isEmpty else {
            hoverEnabled = false
            enterVisible(stale: stale)
            schedulePanelShow(generation: generation)
            scheduleHoverEnable(generation: generation)
            scheduleMinimizedMerge()
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
        enterVisible(stale: stale)
        schedulePanelShow(generation: generation)
        scheduleHoverEnable(generation: generation)
        scheduleMinimizedMerge()

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
                await self.applyPreviews(batchPreviews, generation: generation)
            }

            guard !Task.isCancelled else { return }
            let firstBatchMs = Date().timeIntervalSince(batchStart) * 1000
            let successRate = windowIDs.isEmpty ? 0
                : Double(previews.count) / Double(initialWindowIDs.count)
            let batchSummary = self.performanceMetrics.recordFirstPreviewBatch(milliseconds: firstBatchMs)
            PerformanceDiagnostics.record(
                "first_preview_batch",
                fields: [
                    "captured": .int(previews.count),
                    "initial_requested": .int(initialWindowIDs.count),
                    "milliseconds": .double(firstBatchMs),
                    "success_rate": .double(successRate),
                    "total_capturable": .int(windowIDs.count)
                ]
            )
            if PerformanceLoggingState.mode != .off {
                Logger.switcher.info(
                    "First preview batch: \(previews.count, privacy: .public)/\(initialWindowIDs.count, privacy: .public) in \(firstBatchMs, format: .fixed(precision: 1), privacy: .public) ms (rate \(successRate, format: .fixed(precision: 2), privacy: .public)); rolling n=\(batchSummary.count, privacy: .public), avg=\(batchSummary.average, format: .fixed(precision: 1), privacy: .public), p95=\(batchSummary.p95, format: .fixed(precision: 1), privacy: .public), p99=\(batchSummary.p99, format: .fixed(precision: 1), privacy: .public), max=\(batchSummary.max, format: .fixed(precision: 1), privacy: .public)"
                )
            }

            let firstBatchWindowIDSet = Set(firstBatchWindowIDs)
            let failedInitialWindowIDs = firstBatchWindowIDs.filter { previews[$0] == nil }
            let uncachedDeferredWindowIDs = self.items.compactMap { item -> CGWindowID? in
                guard !item.isMinimized,
                      item.canCapturePreview,
                      item.preview == nil,
                      !firstBatchWindowIDSet.contains(item.windowID) else {
                    return nil
                }
                return item.windowID
            }
            let deferredCandidates = failedInitialWindowIDs + uncachedDeferredWindowIDs
            let deferredWindowIDs = Array(deferredCandidates.prefix(self.deferredPreviewCaptureBudget))
            if PerformanceLoggingState.mode == .debug, !deferredCandidates.isEmpty {
                PerformanceDiagnostics.record(
                    "deferred_preview_selection",
                    fields: [
                        "budget": .int(self.deferredPreviewCaptureBudget),
                        "candidates": .int(deferredCandidates.count),
                        "scheduled": .int(deferredWindowIDs.count),
                        "total_capturable": .int(windowIDs.count)
                    ]
                )
            }
            if !deferredWindowIDs.isEmpty {
                let allPreviews = await catalog.capturePreviews(
                    for: deferredWindowIDs,
                    maxCount: nil,
                    maxConcurrentCaptures: 6
                )
                guard !Task.isCancelled else { return }
                await self.applyPreviews(allPreviews, generation: generation)
            }

            // Refresh SC content cache after a full preview pass. Fast
            // Cmd+Tab+release is covered by the hide/app-activation warmup path.
            Task.detached(priority: .utility) { [catalog] in
                await catalog.refreshContentCache()
            }
        }
    }

    private func applyPreviews(_ previews: [CGWindowID: NSImage], generation: Int) async {
        guard isVisible, previewGeneration == generation else { return }
        // Classify blank/white frames off the main thread, then re-check the
        // generation: the panel may have hidden or reopened during the decode.
        let whiteIDs = await PreviewCacheStore.mostlyWhiteWindowIDs(in: previews)
        guard isVisible, previewGeneration == generation else { return }
        let acceptedPreviews = previewCache.record(previews, liveItems: items, mostlyWhiteIDs: whiteIDs)
        items = items.map { item in
            acceptedPreviews[item.windowID].map { item.withPreview($0) } ?? item
        }
    }

    /// Lazily fetch minimized windows off the main thread and merge them in.
    /// The AX walk is ~150–500 ms with many apps — running it inline would
    /// block the panel from appearing. Called from `showWithPreviews` so the
    /// captured `previewGeneration` matches the just-incremented value the
    /// eventual merge-guard checks against.
    private func scheduleMinimizedMerge() {
        let mergeGeneration = previewGeneration
        let catalog = self.catalog
        Task.detached(priority: .userInitiated) { [weak self] in
            let minimized = await catalog.snapshotMinimized()
            await self?.mergeMinimizedItems(minimized, generation: mergeGeneration)
        }
    }

    private func mergeMinimizedItems(_ minimized: [WindowItem], generation: Int) {
        guard isVisible, previewGeneration == generation, !minimized.isEmpty else { return }
        let existingIDs = Set(items.map(\.id))
        let newItems = minimized
            .filter { !existingIDs.contains($0.id) }
            .map { item in
                SwitchBladeSettings.shared.previewMode == .iconsOnly
                    ? item
                    : previewCache.hydrated(item, liveItems: items + minimized)
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
        recordPanelVisibleMetric(itemCount: items.count)
    }

    private func removeItem(withID id: WindowItem.ID) {
        let removedIndex = items.firstIndex(where: { $0.id == id })
        items.removeAll { $0.id == id }
        mruTracker.dropRank(forID: id)

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
