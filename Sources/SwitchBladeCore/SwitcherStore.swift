import Carbon.HIToolbox
import Combine
import Foundation
import os.log
import SwiftUI

actor WindowActionCoordinator {
    private var isRunning = false

    /// nil means another window operation still owns the single action lane.
    /// The lane stays occupied until detached AX/AppKit work actually returns,
    /// even when the caller task is cancelled meanwhile.
    func run(
        priority: TaskPriority = .userInitiated,
        operation: @escaping @Sendable () -> Bool
    ) async -> Bool? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        return await Task.detached(priority: priority, operation: operation).value
    }
}

/// Observable store backing the SwitcherView. Holds the visible items + the
/// current selection and coordinates between the catalog (window listing),
/// activator (window activation/close/quit/hide), and permission service.
///
/// Preview caching and MRU bookkeeping live in dedicated helper types
/// (`PreviewCacheStore`, `MRUTracker`) — this class only orchestrates them.
@MainActor
final class SwitcherStore: ObservableObject {
    @Published private(set) var items: [WindowItem] = [] {
        didSet {
            // Minimized-window and stale-cache refreshes may change the row count
            // after the panel is already on screen. Keep its frame in sync.
            guard oldValue.count != items.count, !items.isEmpty, isVisible else { return }
            onVisibleItemCountChanged?(items.count)
        }
    }
    @Published private(set) var isVisible = false
    @Published private(set) var permissionState: PermissionState
    @Published private(set) var panelColumnCount = 1
    @Published private(set) var panelTileWidth: CGFloat = 220
    @Published var selectedID: WindowItem.ID?

    var onShow: (() -> Void)?
    var onHide: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenPermissionSettings: ((PermissionKind) -> Void)?
    var onPreparePanel: ((Int) -> Void)?
    var onVisibleItemCountChanged: ((Int) -> Void)?

    var relevantMissingPermissions: [PermissionKind] {
        permissionState.missingPermissions(for: SwitchBladeSettings.shared.previewMode)
    }

    var primaryMissingPermission: PermissionKind? {
        relevantMissingPermissions.first
    }

    var permissionMessage: String? {
        permissionState.message(for: SwitchBladeSettings.shared.previewMode)
    }

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
    private var minimizedMergeTask: Task<Void, Never>?
    private var openRefreshTask: Task<Void, Never>?
    private var staleCacheHealTask: Task<Void, Never>?
    private var contentCacheWarmupTask: Task<Void, Never>?
    private var openItemsWarmupTask: Task<Void, Never>?
    private var panelShowTimer: PanelShowTimer?
    private var panelShowScheduleID = 0
    private var previewWarmupTask: Task<Void, Never>?
    private var focusedRankUpgradeTask: Task<Void, Never>?
    private var backgroundedFocusRankTask: Task<Void, Never>?
    private var windowActionTask: Task<Void, Never>?
    private var windowActionID: UUID?
    private var windowActionGeneration = 0
    private let windowActionCoordinator = WindowActionCoordinator()
    private var settingsCancellables: Set<AnyCancellable> = []
    private var inFlightVisibleSnapshot: InFlightVisibleSnapshot?
    private var previewGeneration = 0
    private var settingsGeneration = 0
    private var pendingOpenRequestedAt: Date?
    private var pendingOpenCycleDelta: Int?
    private var activeOpenRequestedAt: Date?
    private var currentOpenSource: String?
    private var cachedOpenItems: [WindowItem] = []
    private var cachedOpenItemsUpdatedAt: Date?
    private var cachedMinimizedItems: [WindowItem] = []
    private var cachedMinimizedItemsUpdatedAt: Date?
    /// Set when app focus changes outside the switcher after the cache was
    /// built. The cached list may still be young by timestamp, but its first
    /// item can now point at the wrong frontmost app for a fast Cmd+Tab.
    private var cachedOpenItemsNeedResnapshot = false
    nonisolated(unsafe) private var activationObserver: Any?
    /// Prevents the tile under the mouse from stealing selection when the panel first appears.
    private var hoverEnabled = false
    private var currentAppPID: pid_t?
    private var previousAppPID: pid_t?
    private var pendingActivationMeasurements: [pid_t: [PendingActivationMeasurement]] = [:]
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
    private let focusedRankUpgradeDelayNanoseconds: UInt64

    private final class InFlightVisibleSnapshot {
        let diagnosticID: String
        let task: Task<[WindowItem], Never>

        init(diagnosticID: String, task: Task<[WindowItem], Never>) {
            self.diagnosticID = diagnosticID
            self.task = task
        }
    }

    private var openDiagnosticID = UUID().uuidString
    private var lastReturnedSnapshotDiagnosticID: String?

    private final class PanelShowTimer: @unchecked Sendable {
        let workItem: DispatchWorkItem

        init(workItem: DispatchWorkItem) {
            self.workItem = workItem
        }

        func cancel() {
            workItem.cancel()
        }
    }

    private struct PendingActivationMeasurement {
        let id: UUID
        let requestedAt: Date
        let context: String
        let source: String
        let windowID: WindowItem.ID?
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
        focusedRankUpgradeDelayNanoseconds: UInt64 = 150_000_000,
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
        self.focusedRankUpgradeDelayNanoseconds = focusedRankUpgradeDelayNanoseconds
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

        Publishers.CombineLatest4(
            SwitchBladeSettings.shared.$previewMode,
            SwitchBladeSettings.shared.$windowScope,
            SwitchBladeSettings.shared.$hiddenAppsText,
            SwitchBladeSettings.shared.$sortOrder
        )
        .dropFirst()
        .sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateDisplayCachesForSettingsChange()
            }
        }
        .store(in: &settingsCancellables)
    }

    /// Internal entry point for the NSWorkspace activation observer, also
    /// callable directly from tests so the notification queue / RunLoop
    /// plumbing doesn't have to be exercised under XCTest.
    func handleAppActivation(pid: pid_t) {
        let pendingSelfActivation = recordObservedActivationIfNeeded(pid: pid)
        if pid != switchBladePID, !isVisible, !isSwitching {
            if currentAppPID != pid {
                let backgroundedPID = currentAppPID
                // Do NOT discard the backgrounded app's cached preview here.
                // Dropping it made that app — usually the next Cmd+Tab target —
                // flash its icon for a beat until a fresh capture landed. Keep the
                // preview and let the next open's capture replace it in place
                // (stale-while-revalidate); a briefly-stale thumbnail beats a blank.
                previousAppPID = currentAppPID
                currentAppPID = pid
                cachedOpenItemsNeedResnapshot = true
                // An exact self-initiated window switch already moved the
                // selected rank to the front through rememberSelection. Do not
                // reinterpret the previous app's post-transition AX focus as a
                // second user focus event: multi-window apps such as Outlook can
                // report a different sibling after the programmatic raise/focus.
                if pendingSelfActivation?.windowID == nil,
                   let backgroundedPID,
                   backgroundedPID != switchBladePID {
                    scheduleBackgroundedWindowRankUpgrade(
                        pid: backgroundedPID,
                        expectedCurrentPID: pid
                    )
                }
            }
            // A window-targeted self-activation was already recorded exactly by
            // rememberSelection at commit; re-tracking it would only stack an
            // identity-only rank on top of the concrete one. App-level self
            // switches (windowID nil, e.g. the fast previous-app path) fall
            // through on purpose: the exact window is unknown, so they need
            // the same coarse track + AX upgrade as an external activation.
            if pendingSelfActivation?.windowID == nil {
                let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                mruTracker.trackSystemActivation(pid, in: items, bundleIdentifier: bundleIdentifier)
                scheduleFocusedWindowRankUpgrade(pid: pid)
            }
        }
        // Opportunistic cache warmup — gated on recent-use so we don't burn
        // cycles for users who haven't touched the switcher in a while.
        guard Date().timeIntervalSince(lastSwitcherUse) < activationWarmupWindow else { return }
        scheduleContentCacheWarmup(delayNanoseconds: 250_000_000)
        scheduleOpenItemsCacheWarmup(context: "app activation", delayNanoseconds: 250_000_000)
        schedulePreviewCacheWarmup(context: "app activation", delayNanoseconds: 250_000_000)
    }

    deinit {
        contentCacheWarmupTask?.cancel()
        openItemsWarmupTask?.cancel()
        openRefreshTask?.cancel()
        panelShowTimer?.cancel()
        staleCacheHealTask?.cancel()
        previewWarmupTask?.cancel()
        focusedRankUpgradeTask?.cancel()
        backgroundedFocusRankTask?.cancel()
        windowActionTask?.cancel()
        minimizedMergeTask?.cancel()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    @discardableResult
    func refreshPermissionState(_ state: PermissionState? = nil) -> Bool {
        let current = state ?? permissionService.currentState()
        guard current != permissionState else { return false }
        permissionState = current
        return true
    }

    func invalidateCaptureCache(reason: String) async {
        await catalog.invalidateContentCache(reason: reason)
    }

    func warmPreviewCache(context: String) async {
        guard SwitchBladeSettings.shared.previewMode != .iconsOnly else { return }
        guard !isVisible, !isSwitching else { return }
        let generation = settingsGeneration

        let visibleSnapshot = await snapshotVisibleOnlyOffMain()
        guard !Task.isCancelled,
              settingsGeneration == generation,
              !isVisible,
              !isSwitching else { return }
        let orderedItems = orderItems(mruTracker.orderedForDisplay(from: visibleSnapshot, context: "warm-preview", snapshotDiagnosticID: lastReturnedSnapshotDiagnosticID))
        let stabilizedItems = stabilizeBackgroundWarmupOrder(
            orderedItems,
            context: context,
            retainMissingCurrentAppWindows: true
        )
        let cacheItems = updateCachedOpenItems(stabilizedItems)
        let windowIDs = stabilizedItems
            .filter { !$0.isMinimized && $0.canCapturePreview }
            .map(\.windowID)
        let initialWindowIDs = Array(windowIDs.prefix(4))
        guard !initialWindowIDs.isEmpty else { return }
        guard !Task.isCancelled else { return }

        let start = Date()
        let previews = await catalog.capturePreviews(
            for: initialWindowIDs,
            maxCount: nil,
            maxConcurrentCaptures: min(4, initialWindowIDs.count),
            allowedOffscreenWindowIDs: []
        )
        guard !Task.isCancelled,
              settingsGeneration == generation,
              !isVisible,
              !isSwitching else { return }
        let classifications = await PreviewCacheStore.classifyCapturedFrames(previews)
        guard !Task.isCancelled,
              settingsGeneration == generation,
              !isVisible,
              !isSwitching else { return }
        recordRejectedBlackFrames(classifications)
        let acceptedPreviews = previewCache.record(
            previews,
            liveItems: cacheItems,
            classifications: classifications
        )
        primeHiddenDisplayItems(cacheItems)
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
        guard windowActionTask == nil else {
            Logger.switcher.info("Cmd+Tab ignored while a committed window action is in flight")
            return
        }
        if isVisible {
            cycle(forward: forward)
            return
        }
        if case .previewHidden = phase {
            showPreparedPanelIfNeeded()
            moveSelection(forward ? 1 : -1)
            return
        }
        // Preserve navigation input while the first off-main snapshot is still
        // resolving. Starting another open would duplicate the work, but dropping
        // the key-down makes rapid Cmd+Tab stop one window early.
        if isSwitching {
            pendingOpenCycleDelta = (pendingOpenCycleDelta ?? 0) + (forward ? 1 : -1)
            return
        }

        lastSwitcherUse = Date()
        contentCacheWarmupTask?.cancel()
        openItemsWarmupTask?.cancel()
        openRefreshTask?.cancel()
        cancelPanelShow()
        previewWarmupTask?.cancel()
        pendingOpenRequestedAt = Date()
        pendingOpenCycleDelta = forward ? 1 : -1
        activeOpenRequestedAt = pendingOpenRequestedAt
        enterResolving(commitWhenReady: false)

        openDiagnosticID = UUID().uuidString
        PerformanceDiagnostics.record("open_cache_decision", fields: [
            "open_id": .string(openDiagnosticID),
            "cached_count": .int(cachedOpenItems.count),
            "current_pid": .int(Int(currentAppPID ?? -1)),
            "cached_current_app_count": .int(cachedOpenItems.filter { $0.pid == currentAppPID }.count),
            "cache_fresh": .bool(isCachedOpenItemsFresh()),
            "needs_resnapshot": .bool(cachedOpenItemsNeedResnapshot)
        ])

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
                openFromFreshSnapshotOffMain(
                    stabilizeWithCachedOrder: cachedOpenItemsRequireFreshSnapshotForCurrentApp()
                )
                return
            }
            if cachedOpenItemsRequireFreshSnapshotForCurrentApp() {
                Logger.switcher.info(
                    "Bypassing cached open items for current multi-window app"
                )
                openFromFreshSnapshotOffMain(stabilizeWithCachedOrder: true)
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

        let switcherModifier = SwitchBladeSettings.shared.modifier.nsFlag
        let snapModifier = Self.snapShortcutModifier(for: switcherModifier)
        guard !Self.isVoiceOverChord(event.modifierFlags) else {
            return false
        }
        switch Int(event.keyCode) {
        case Int(kVK_RightArrow) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: snapModifier,
            switcherModifier: switcherModifier
        ):
            snapSelected(to: .right)
            return true
        case Int(kVK_LeftArrow) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: snapModifier,
            switcherModifier: switcherModifier
        ):
            snapSelected(to: .left)
            return true
        case Int(kVK_UpArrow) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: snapModifier,
            switcherModifier: switcherModifier
        ):
            snapSelected(to: .top)
            return true
        case Int(kVK_DownArrow) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: snapModifier,
            switcherModifier: switcherModifier
        ):
            snapSelected(to: .bottom)
            return true
        case Int(kVK_Tab) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: .shift,
            switcherModifier: switcherModifier
        ):
            moveSelection(-1)
            return true
        case Int(kVK_Tab) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: [],
            switcherModifier: switcherModifier
        ):
            moveSelection(1)
            return true
        case Int(kVK_RightArrow) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: [],
            switcherModifier: switcherModifier
        ):
            moveGridSelection(.right)
            return true
        case Int(kVK_LeftArrow) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: [],
            switcherModifier: switcherModifier
        ):
            moveGridSelection(.left)
            return true
        case Int(kVK_DownArrow) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: [],
            switcherModifier: switcherModifier
        ):
            moveGridSelection(.down)
            return true
        case Int(kVK_UpArrow) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: [],
            switcherModifier: switcherModifier
        ):
            moveGridSelection(.up)
            return true
        case Int(kVK_Home) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: [],
            switcherModifier: switcherModifier
        ):
            selectFirst()
            return true
        case Int(kVK_End) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: [],
            switcherModifier: switcherModifier
        ):
            selectLast()
            return true
        case Int(kVK_ANSI_Q) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: .command,
            switcherModifier: switcherModifier
        ):
            quitSelectedApp()
            return true
        case Int(kVK_ANSI_H) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: .command,
            switcherModifier: switcherModifier
        ):
            hideSelectedApp()
            return true
        case Int(kVK_ANSI_Comma) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: .command,
            switcherModifier: switcherModifier
        ):
            openSettings()
            return true
        case Int(kVK_Return) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: [],
            switcherModifier: switcherModifier
        ):
            commitSelection()
            return true
        case Int(kVK_Space) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: [],
            switcherModifier: switcherModifier
        ):
            commitSelection()
            return true
        case Int(kVK_Escape) where Self.panelShortcutMatches(
            flags: event.modifierFlags,
            required: [],
            switcherModifier: switcherModifier
        ):
            cancel()
            return true
        default:
            return false
        }
    }

    static func panelShortcutMatches(
        flags: NSEvent.ModifierFlags,
        required: NSEvent.ModifierFlags,
        switcherModifier: NSEvent.ModifierFlags
    ) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let actual = flags.intersection(relevant)
        return actual == required || actual == required.union(switcherModifier)
    }

    static func isVoiceOverChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        let actual = flags.intersection([.command, .option, .control, .shift])
        return actual.contains(.control) && actual.contains(.option)
    }

    /// Control+Option is reserved for VoiceOver. When Control is the configured
    /// switcher modifier, use Shift+Arrow for keyboard snapping so both features
    /// remain reachable without stealing VoiceOver input.
    static func snapShortcutModifier(
        for switcherModifier: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        switcherModifier == .control ? .shift : .option
    }

    enum GridNavigationDirection {
        case left
        case right
        case up
        case down
    }

    func updatePanelColumnCount(_ columns: Int) {
        panelColumnCount = max(1, columns)
    }

    func updatePanelLayout(columns: Int, tileWidth: CGFloat) {
        panelColumnCount = max(1, columns)
        panelTileWidth = tileWidth.isFinite && tileWidth > 0 ? tileWidth : 220
    }

    static func gridNavigationIndex(
        from currentIndex: Int,
        itemCount: Int,
        columns: Int,
        direction: GridNavigationDirection
    ) -> Int {
        guard itemCount > 0 else { return 0 }
        let index = min(max(0, currentIndex), itemCount - 1)
        let columnCount = max(1, columns)
        switch direction {
        case .left:
            return max((index / columnCount) * columnCount, index - 1)
        case .right:
            let rowEnd = min(itemCount - 1, ((index / columnCount) + 1) * columnCount - 1)
            return min(rowEnd, index + 1)
        case .up:
            return max(0, index - columnCount)
        case .down:
            return min(itemCount - 1, index + columnCount)
        }
    }

    private func moveGridSelection(_ direction: GridNavigationDirection) {
        guard !items.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let targetIndex = Self.gridNavigationIndex(
            from: currentIndex,
            itemCount: items.count,
            columns: panelColumnCount,
            direction: direction
        )
        selectedID = items[targetIndex].id
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
        guard !item.isApplicationFallback else {
            Logger.switcher.info(
                "Snap ignored for app-only item id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public)"
            )
            return
        }
        selectedID = item.id
        performSelectionAction(for: item, actionName: "snap-\(edge.rawValue)") { activator, selectedItem in
            activator.snap(selectedItem, to: edge)
        }
    }

    func close(_ item: WindowItem) {
        guard !item.isApplicationFallback else {
            Logger.switcher.info(
                "Close ignored for app-only item id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public)"
            )
            return
        }
        let activator = self.activator
        let target = item.actionTarget
        _ = startWindowAction(
            operation: { activator.close(target) },
            completion: { [weak self] succeeded in
                guard let self else { return }
                guard succeeded else {
                    Logger.switcher.notice(
                        "Close action failed id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public); keeping item visible"
                    )
                    return
                }
                self.removeItem(withID: item.id)
            }
        )
    }

    /// Quits the entire app of the selected window. The switcher hides; if
    /// other windows of the same pid are also listed, they're removed too.
    private func quitSelectedApp() {
        guard let selected = selectedItem else { return }
        let activator = self.activator
        let target = selected.actionTarget
        _ = startWindowAction(
            operation: { activator.quit(target) },
            completion: { [weak self] succeeded in
                guard let self else { return }
                guard succeeded else {
                    Logger.switcher.notice(
                        "Quit action failed id=\(selected.id, privacy: .public) pid=\(selected.pid, privacy: .public); keeping panel state"
                    )
                    return
                }
                self.items.removeAll { $0.pid == selected.pid }
                self.mruTracker.dropAllRanks(
                    forAppIdentity: selected.bundleIdentifier ?? selected.appName,
                    bundleIdentifier: selected.bundleIdentifier
                )
                self.recordDisplayOrder(context: "quit")
                self.items.isEmpty ? self.cancel() : self.hide()
            }
        )
    }

    /// Hides all windows of the selected app, keeping the app running. The
    /// switcher closes; the items list is intact for the next cold open.
    private func hideSelectedApp() {
        guard let selected = selectedItem else { return }
        let activator = self.activator
        let target = selected.actionTarget
        _ = startWindowAction(
            operation: { activator.hide(target) },
            completion: { [weak self] succeeded in
                guard let self else { return }
                guard succeeded else {
                    Logger.switcher.notice(
                        "Hide action failed id=\(selected.id, privacy: .public) pid=\(selected.pid, privacy: .public); keeping panel visible"
                    )
                    return
                }
                self.hide()
            }
        )
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
                performSelectionAction(
                    for: item,
                    actionName: "activate",
                    updateCachedSelectionState: true,
                    dismissVisiblePanelImmediately: true
                ) { activator, selectedItem in
                    Self.activateSelectionTarget(selectedItem, using: activator)
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
        performSelectionAction(
            for: item,
            actionName: "activate",
            updateCachedSelectionState: true,
            dismissVisiblePanelImmediately: true
        ) { activator, selectedItem in
            Self.activateSelectionTarget(selectedItem, using: activator)
        }
    }

    func cancel() {
        hide()
    }

    func openSettings() {
        hide()
        onOpenSettings?()
    }

    func openPrimaryPermissionSettings() {
        refreshPermissionState()
        guard let permission = primaryMissingPermission else { return }
        hide()
        onOpenPermissionSettings?(permission)
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
        let switchStart = Date()
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
            isResolvingPreviousSwitch = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isResolvingPreviousSwitch = false }
                await self.performFastPreviousApplicationSwitch(
                    targetPID: targetPID,
                    switchStart: switchStart
                )
            }
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
            await self.performPreviousApplicationSwitch(orderedItems: orderedItems, switchStart: switchStart)
        }
    }

    private func performPreviousApplicationSwitch(orderedItems: [WindowItem], switchStart: Date) async {
        let effectiveCurrentPID = orderedItems.first?.pid ?? currentAppPID
        if let targetItem = previousSwitchTarget(from: orderedItems, currentPID: effectiveCurrentPID) {
            Logger.switcher.info(
                "Double modifier switching window current=\(effectiveCurrentPID ?? -1, privacy: .public) targetWindow=\(targetItem.id, privacy: .public) targetPID=\(targetItem.pid, privacy: .public)"
            )
            let activator = self.activator
            let target = targetItem.actionTarget
            guard await runActivatorOperation({
                Self.activateSelectionTarget(target, using: activator)
            }) else {
                Logger.switcher.notice(
                    "Double modifier window activation failed targetWindow=\(targetItem.id, privacy: .public) targetPID=\(targetItem.pid, privacy: .public); preserving app history"
                )
                return
            }
            lastSwitcherUse = Date()
            mruTracker.rememberSelection(targetItem.id, in: orderedItems, context: "double-modifier-window")
            if let effectiveCurrentPID, effectiveCurrentPID != switchBladePID, effectiveCurrentPID != targetItem.pid {
                previousAppPID = effectiveCurrentPID
            }
            currentAppPID = targetItem.pid
            recordPreviousSwitchDispatch(
                context: "modifier-window",
                switchStart: switchStart,
                targetPID: targetItem.pid,
                windowID: targetItem.id
            )
            return
        }

        guard let targetPID = previousApplicationPID(currentPID: effectiveCurrentPID, orderedItems: orderedItems) else {
            Logger.switcher.info(
                "Double modifier switch ignored: no previous app current=\(effectiveCurrentPID ?? -1, privacy: .public) previous=\(self.previousAppPID ?? -1, privacy: .public)"
            )
            return
        }

        Logger.switcher.info(
            "Double modifier switching app current=\(effectiveCurrentPID ?? -1, privacy: .public) target=\(targetPID, privacy: .public)"
        )
        let activator = self.activator
        let activationRequestID = markActivationRequest(
            pid: targetPID,
            context: "modifier-app",
            source: "previous-switch",
            windowID: nil
        )
        guard await runActivatorOperation({ activator.activateApplication(pid: targetPID) }) else {
            cancelActivationRequest(pid: targetPID, id: activationRequestID)
            Logger.switcher.notice(
                "Double modifier app activation failed target=\(targetPID, privacy: .public); preserving app history"
            )
            return
        }
        lastSwitcherUse = Date()
        if let effectiveCurrentPID, effectiveCurrentPID != switchBladePID {
            previousAppPID = effectiveCurrentPID
        }
        currentAppPID = targetPID
        recordPreviousSwitchDispatch(
            context: "modifier-app",
            switchStart: switchStart,
            targetPID: targetPID,
            windowID: nil
        )
    }

    private func performFastPreviousApplicationSwitch(targetPID: pid_t, switchStart: Date) async {
        guard let effectiveCurrentPID = currentAppPID else { return }
        Logger.switcher.info(
            "Fast previous-app switch current=\(effectiveCurrentPID, privacy: .public) target=\(targetPID, privacy: .public)"
        )
        let activator = self.activator
        let activationRequestID = markActivationRequest(
            pid: targetPID,
            context: "modifier-fast-app",
            source: "previous-switch",
            windowID: nil
        )
        guard await runActivatorOperation({ activator.activateApplication(pid: targetPID) }) else {
            cancelActivationRequest(pid: targetPID, id: activationRequestID)
            Logger.switcher.notice(
                "Fast previous-app activation failed target=\(targetPID, privacy: .public); preserving app history"
            )
            return
        }
        lastSwitcherUse = Date()
        previousAppPID = effectiveCurrentPID
        currentAppPID = targetPID
        recordPreviousSwitchDispatch(
            context: "modifier-fast-app",
            switchStart: switchStart,
            targetPID: targetPID,
            windowID: nil
        )
    }

    private func runActivatorOperation(
        _ operation: @escaping @Sendable () -> Bool
    ) async -> Bool {
        guard let result = await windowActionCoordinator.run(operation: operation) else {
            Logger.switcher.notice("Window action ignored while another detached action is still running")
            return false
        }
        return result
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
        return mruTracker.orderedForDisplay(from: snapshot, context: "previous-switch-target", snapshotDiagnosticID: lastReturnedSnapshotDiagnosticID)
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

    private nonisolated static func activateSelectionTarget(
        _ item: WindowActionTarget,
        using activator: WindowActivating
    ) -> Bool {
        if item.isApplicationFallback {
            return activator.reopenApplication(pid: item.pid)
        }
        return activator.activate(item)
    }

    @discardableResult
    private func performSelectionAction(
        for item: WindowItem,
        liveItems: [WindowItem]? = nil,
        actionName: String,
        source: String? = nil,
        updateCachedSelectionState: Bool = false,
        dismissVisiblePanelImmediately: Bool = false,
        action: @escaping @Sendable (WindowActivating, WindowActionTarget) -> Bool
    ) -> Bool {
        let actionStart = Date()
        let liveItems = liveItems ?? items
        let actionSource = source ?? currentOpenSource ?? "unknown"
        let activator = self.activator
        let catalog = self.catalog
        let target = item.actionTarget
        let dismissBeforeCompletion = dismissVisiblePanelImmediately && isVisible
        let backgroundedPID = currentAppPID.flatMap { pid in
            pid != item.pid && pid != switchBladePID ? pid : nil
        }
        let backgroundedFocusBeforeActivation = LockedValue<WindowItem?>(nil)
        let focusDiagnosticID = UUID().uuidString
        let activationRequestID = item.pid != currentAppPID
            ? markActivationRequest(
                pid: item.pid,
                context: "selection-\(actionName)",
                source: actionSource,
                windowID: item.id
            )
            : nil
        Logger.switcher.info(
            "Begin selection action=\(actionName, privacy: .public) source=\(actionSource, privacy: .public) item id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public)"
        )
        let started = startWindowAction(
            operation: {
                if let backgroundedPID {
                    backgroundedFocusBeforeActivation.value = Self.diagnosticFocusedWindow(
                        catalog: catalog, pid: backgroundedPID,
                        diagnosticID: focusDiagnosticID, context: "pre-activation-backgrounded-focus"
                    )
                }
                return action(activator, target)
            },
            completion: { [weak self] didPerformAction in
                self?.completeSelectionAction(
                    didPerformAction: didPerformAction,
                    item: item,
                    liveItems: liveItems,
                    actionName: actionName,
                    actionSource: actionSource,
                    updateCachedSelectionState: updateCachedSelectionState,
                    dismissedBeforeCompletion: dismissBeforeCompletion,
                    actionStart: actionStart,
                    activationRequestID: activationRequestID,
                    backgroundedFocusBeforeActivation: backgroundedFocusBeforeActivation.value,
                    focusDiagnosticID: focusDiagnosticID,
                    backgroundedFocusWasRequested: backgroundedPID != nil
                )
            }
        )
        if !started, let activationRequestID {
            cancelActivationRequest(pid: item.pid, id: activationRequestID)
        }
        if started, dismissBeforeCompletion {
            hide(cancelWindowAction: false, scheduleWarmups: false)
        }
        return started
    }

    @discardableResult
    private func startWindowAction(
        operation: @escaping @Sendable () -> Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard windowActionTask == nil else {
            Logger.switcher.notice("Window action ignored while another action is in flight")
            return false
        }
        let generation = windowActionGeneration
        let actionID = UUID()
        windowActionID = actionID
        windowActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.windowActionCoordinator.run(operation: operation)
            if self.windowActionID == actionID {
                self.windowActionTask = nil
                self.windowActionID = nil
            }
            guard let result,
                  !Task.isCancelled,
                  self.windowActionGeneration == generation else { return }
            completion(result)
        }
        return true
    }

    private func completeSelectionAction(
        didPerformAction: Bool,
        item: WindowItem,
        liveItems: [WindowItem],
        actionName: String,
        actionSource: String,
        updateCachedSelectionState: Bool,
        dismissedBeforeCompletion: Bool,
        actionStart: Date,
        activationRequestID: UUID?,
        backgroundedFocusBeforeActivation: WindowItem?,
        focusDiagnosticID: String,
        backgroundedFocusWasRequested: Bool
    ) {
        let actionMs = Date().timeIntervalSince(actionStart) * 1000
        guard didPerformAction else {
            recordFocusRankDecision(item: backgroundedFocusBeforeActivation, diagnosticID: focusDiagnosticID,
                                    context: "pre-activation-backgrounded-focus", outcome: "discarded-action-failed")
            if let activationRequestID {
                cancelActivationRequest(pid: item.pid, id: activationRequestID)
            }
            Logger.switcher.notice(
                "Selection action failed action=\(actionName, privacy: .public) source=\(actionSource, privacy: .public) item id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public); preserving state"
            )
            PerformanceDiagnostics.record(
                "selection_action_failed",
                fields: [
                    "action": .string(actionName),
                    "action_ms": .double(actionMs),
                    "pid": .int(Int(item.pid)),
                    "source": .string(actionSource),
                    "window_id": .int(Int(item.id))
                ]
            )
            if dismissedBeforeCompletion {
                applyDisplayItems(hydratedForDisplay(liveItems), selectedID: item.id)
                enterPreviewHidden(stale: false)
                showPreparedPanelIfNeeded()
            } else if !isVisible {
                if case .resolving = phase {
                    applyDisplayItems(hydratedForDisplay(liveItems), selectedID: item.id)
                    enterPreviewHidden(stale: false)
                }
                showPreparedPanelIfNeeded()
            }
            return
        }

        let rememberStart = Date()
        mruTracker.rememberSelection(
            item.id,
            in: liveItems,
            context: "selection-\(actionName)-source=\(actionSource)-stale=\(currentShowingStale)"
        )
        if let backgroundedFocusBeforeActivation,
           !backgroundedFocusBeforeActivation.isApplicationFallback {
            recordFocusRankDecision(item: backgroundedFocusBeforeActivation, diagnosticID: focusDiagnosticID,
                                    context: "pre-activation-backgrounded-focus", outcome: "accepted")
            mruTracker.trackBackgroundedWindowFocus(
                backgroundedFocusBeforeActivation,
                context: "pre-activation-backgrounded-focus"
            )
        } else if backgroundedFocusWasRequested {
            recordFocusRankDecision(item: backgroundedFocusBeforeActivation, diagnosticID: focusDiagnosticID,
                                    context: "pre-activation-backgrounded-focus", outcome: "discarded-unresolved-or-fallback")
        }
        let rememberMs = Date().timeIntervalSince(rememberStart) * 1000
        let cacheSyncStart = Date()
        if updateCachedSelectionState {
            syncCachedOpenStateAfterSelection(item, liveItems: liveItems)
        }
        let cacheSyncMs = Date().timeIntervalSince(cacheSyncStart) * 1000
        let scheduledAt = Date()
        if dismissedBeforeCompletion {
            schedulePostHideWarmups()
        } else {
            hide()
        }
        let dispatchDelayMs = Date().timeIntervalSince(scheduledAt) * 1000
        let preHideMs = scheduledAt.timeIntervalSince(actionStart) * 1000
        let totalPrepareMs = Date().timeIntervalSince(actionStart) * 1000
        PerformanceDiagnostics.record(
            "selection_action_dispatch",
            fields: [
                "action": .string(actionName),
                "action_ms": .double(actionMs),
                "cache_sync_ms": .double(cacheSyncMs),
                "dispatch_delay_ms": .double(dispatchDelayMs),
                "hide_ms": .double(dispatchDelayMs),
                "pid": .int(Int(item.pid)),
                "pre_hide_ms": .double(preHideMs),
                "remember_ms": .double(rememberMs),
                "source": .string(actionSource),
                "total_prepare_ms": .double(totalPrepareMs),
                "window_id": .int(Int(item.id))
            ]
        )
        Logger.switcher.info(
            "Dispatch selection action=\(actionName, privacy: .public) source=\(actionSource, privacy: .public) item id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public) delay=\(dispatchDelayMs, format: .fixed(precision: 1), privacy: .public)ms"
        )
    }

    private func syncCachedOpenStateAfterSelection(_ item: WindowItem, liveItems: [WindowItem]) {
        guard !liveItems.isEmpty else { return }

        let reorderedItems = [item] + liveItems.filter { $0.id != item.id }
        let frontmostAdjustedItems = reorderedItems.map { candidate in
            candidate.withFrontmostState(candidate.pid == item.pid)
        }
        updateCachedOpenItems(orderItems(frontmostAdjustedItems))
    }

    private func hydratedForDisplay(_ sourceItems: [WindowItem]) -> [WindowItem] {
        guard SwitchBladeSettings.shared.previewMode != .iconsOnly else {
            return sourceItems.map { $0.withPreview(nil) }
        }
        return sourceItems.map { previewCache.hydrated($0, liveItems: sourceItems) }
    }

    private func invalidateDisplayCachesForSettingsChange() {
        settingsGeneration &+= 1
        previewGeneration += 1
        previewLoadTask?.cancel()
        previewLoadTask = nil
        minimizedMergeTask?.cancel()
        minimizedMergeTask = nil
        staleCacheHealTask?.cancel()
        staleCacheHealTask = nil
        openRefreshTask?.cancel()
        openRefreshTask = nil
        openItemsWarmupTask?.cancel()
        openItemsWarmupTask = nil
        previewWarmupTask?.cancel()
        previewWarmupTask = nil
        // A detached snapshot already executing cannot be interrupted, but its
        // old filter/scope result must never be reused after this invalidation.
        inFlightVisibleSnapshot = nil
        cachedOpenItems = []
        cachedOpenItemsUpdatedAt = nil
        cachedMinimizedItems = []
        cachedMinimizedItemsUpdatedAt = nil
        cachedOpenItemsNeedResnapshot = false
        previewCache.removeAll()

        if SwitchBladeSettings.shared.previewMode == .iconsOnly {
            items = items.map { $0.withPreview(nil) }
        } else if !isVisible, !isSwitching {
            items = []
            selectedID = nil
        }
    }

    private func defaultSelectedID(in orderedItems: [WindowItem]) -> WindowItem.ID? {
        orderedItems.indices.contains(1) ? orderedItems[1].id : orderedItems.first?.id
    }

    private func pendingOpenSelectedID(in orderedItems: [WindowItem]) -> WindowItem.ID? {
        guard !orderedItems.isEmpty else { return nil }
        guard let pendingOpenCycleDelta else {
            if let selectedID, orderedItems.contains(where: { $0.id == selectedID }) {
                return selectedID
            }
            return defaultSelectedID(in: orderedItems)
        }

        let count = orderedItems.count
        let index = ((pendingOpenCycleDelta % count) + count) % count
        return orderedItems[index].id
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

    private func hide(
        cancelWindowAction: Bool = true,
        scheduleWarmups: Bool = true
    ) {
        if cancelWindowAction {
            windowActionGeneration &+= 1
            windowActionTask?.cancel()
            windowActionTask = nil
            windowActionID = nil
        }
        previewGeneration += 1
        previewLoadTask?.cancel()
        previewLoadTask = nil
        minimizedMergeTask?.cancel()
        minimizedMergeTask = nil
        openItemsWarmupTask?.cancel()
        openRefreshTask?.cancel()
        cancelPanelShow()
        previewWarmupTask?.cancel()
        enterIdle()
        hoverEnabled = false
        pendingOpenRequestedAt = nil
        pendingOpenCycleDelta = nil
        activeOpenRequestedAt = nil
        currentOpenSource = nil
        onHide?()
        if scheduleWarmups {
            schedulePostHideWarmups()
        }
    }

    private func schedulePostHideWarmups() {
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
            pendingOpenCycleDelta = nil
            enterIdle()
            Logger.switcher.notice("Cycle aborted: snapshot is empty")
            return
        }

        currentOpenSource = source
        let displayOrderedItems = updateCachedItems
            ? updateCachedOpenItems(orderedItems)
            : orderedItemsWithRememberedMinimizedItems(
                orderedItems,
                context: "cached-open-display"
            )
        // Display staleness is carried into the visible/previewHidden phase by the
        // mutators at the end of this method (enterPreviewHidden / enterVisible).
        let preselectedID = pendingOpenSelectedID(in: displayOrderedItems)
        pendingOpenCycleDelta = nil

        // Quick Cmd+Tab release should not pay the panel show or preview path
        // once the target window has already been resolved off-main.
        if case .resolving(let commitWhenReady) = phase, commitWhenReady {
            logOpenOrdering(source: "\(source)-quick-release", orderedItems: displayOrderedItems, selectedID: preselectedID)
            let quickSwitchMs = Date().timeIntervalSince(openStart) * 1000
            if PerformanceLoggingState.mode != .off {
                if let queueMs {
                    Logger.switcher.info(
                        "Quick release before panel show: \(displayOrderedItems.count, privacy: .public) windows ready in \(quickSwitchMs, format: .fixed(precision: 1), privacy: .public) ms; source=\(source, privacy: .public), queue=\(queueMs, format: .fixed(precision: 1), privacy: .public), permission=\(permissionMs, format: .fixed(precision: 1), privacy: .public), snapshot=\(snapshotMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public)"
                    )
                } else {
                    Logger.switcher.info(
                        "Quick release before panel show: \(displayOrderedItems.count, privacy: .public) windows ready in \(quickSwitchMs, format: .fixed(precision: 1), privacy: .public) ms; source=\(source, privacy: .public), queue=n/a, permission=\(permissionMs, format: .fixed(precision: 1), privacy: .public), snapshot=\(snapshotMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public)"
                    )
                }
            }

            // Success clears commitWhenReady through hide() → enterIdle(). A
            // failed activation is converted into a visible prepared panel.
            guard let preselectedID,
                  let item = displayOrderedItems.first(where: { $0.id == preselectedID }) else {
                Logger.switcher.notice("Quick release aborted: no selected item after snapshot")
                hide()
                return
            }

            performSelectionAction(
                for: item,
                liveItems: displayOrderedItems,
                actionName: "activate",
                source: source
            ) { activator, selectedItem in
                Self.activateSelectionTarget(selectedItem, using: activator)
            }
            return
        }

        let hydrateStart = Date()
        let hydratedItems = hydratedForDisplay(displayOrderedItems)
        let hydrateMs = Date().timeIntervalSince(hydrateStart) * 1000
        // Preselect the second item so a tap-Cmd+Tab+release toggles between
        // the two most-recent windows. With only one item, select that.
        applyDisplayItems(hydratedItems, selectedID: preselectedID)
        logOpenOrdering(source: source, orderedItems: displayOrderedItems, selectedID: selectedID)

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
            "window_count": .int(displayOrderedItems.count)
        ]
        if let queueMs {
            coldFields["queue_ms"] = .double(queueMs)
        }
        coldFields["snapshot_ms"] = .double(snapshotMs)
        PerformanceDiagnostics.record("cold_open", fields: coldFields)
        if PerformanceLoggingState.mode != .off {
            if let queueMs {
                Logger.switcher.info(
                    "Cold-open: \(displayOrderedItems.count, privacy: .public) windows in \(coldMs, format: .fixed(precision: 1), privacy: .public) ms, \(cachedHits, privacy: .public) from cache; source=\(source, privacy: .public), queue=\(queueMs, format: .fixed(precision: 1), privacy: .public), permission=\(permissionMs, format: .fixed(precision: 1), privacy: .public), snapshot=\(snapshotMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public), hydrate=\(hydrateMs, format: .fixed(precision: 1), privacy: .public); rolling n=\(coldSummary.count, privacy: .public), avg=\(coldSummary.average, format: .fixed(precision: 1), privacy: .public), p95=\(coldSummary.p95, format: .fixed(precision: 1), privacy: .public), p99=\(coldSummary.p99, format: .fixed(precision: 1), privacy: .public), max=\(coldSummary.max, format: .fixed(precision: 1), privacy: .public)"
                )
            } else {
                Logger.switcher.info(
                    "Cold-open: \(displayOrderedItems.count, privacy: .public) windows in \(coldMs, format: .fixed(precision: 1), privacy: .public) ms, \(cachedHits, privacy: .public) from cache; source=\(source, privacy: .public), queue=n/a, permission=\(permissionMs, format: .fixed(precision: 1), privacy: .public), snapshot=\(snapshotMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public), hydrate=\(hydrateMs, format: .fixed(precision: 1), privacy: .public); rolling n=\(coldSummary.count, privacy: .public), avg=\(coldSummary.average, format: .fixed(precision: 1), privacy: .public), p95=\(coldSummary.p95, format: .fixed(precision: 1), privacy: .public), p99=\(coldSummary.p99, format: .fixed(precision: 1), privacy: .public), max=\(coldSummary.max, format: .fixed(precision: 1), privacy: .public)"
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

    private func openFromFreshSnapshotOffMain(stabilizeWithCachedOrder: Bool = false) {
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
            self.rememberFrontmostWindowFocusIfNeeded(in: visibleSnapshot)
            let snapshotOrderedItems = self.orderItems(
                self.mruTracker.orderedForDisplay(from: visibleSnapshot, context: "request-snapshot", snapshotDiagnosticID: self.lastReturnedSnapshotDiagnosticID)
            )
            let orderedItems = stabilizeWithCachedOrder
                ? self.stabilizeBackgroundWarmupOrder(
                    snapshotOrderedItems,
                    context: "current-app-cache-validation",
                    retainMissingCurrentAppWindows: false
                )
                : snapshotOrderedItems
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
            self.rememberFrontmostWindowFocusIfNeeded(in: visibleSnapshot)
            let orderedItems = self.orderItems(self.mruTracker.orderedForDisplay(from: visibleSnapshot, context: "stale-heal", snapshotDiagnosticID: self.lastReturnedSnapshotDiagnosticID))
            let orderMs = Date().timeIntervalSince(orderStart) * 1000
            guard !orderedItems.isEmpty else { return }

            let cacheItems = self.updateCachedOpenItems(orderedItems)

            if self.currentShowingStale {
                let hydrateMs = self.applyStaleCacheRefresh(
                    cacheItems,
                    showAfterRefresh: self.isVisible
                )
                if PerformanceLoggingState.mode != .off {
                    Logger.switcher.info(
                        "Open-items refresh after stale cache: \(cacheItems.count, privacy: .public) windows; snapshot=\(snapshotMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public), hydrate=\(hydrateMs, format: .fixed(precision: 1), privacy: .public)"
                    )
                }
            } else if PerformanceLoggingState.mode != .off {
                Logger.switcher.info(
                    "Open-items cache healed after stale cache: \(cacheItems.count, privacy: .public) windows; snapshot=\(snapshotMs, format: .fixed(precision: 1), privacy: .public), order=\(orderMs, format: .fixed(precision: 1), privacy: .public)"
                )
            }
        }
    }

    /// `didActivateApplication` does not fire when focus moves between windows
    /// of the already-frontmost app. A user-initiated fresh open has already
    /// resolved that app's focused AX window to the first same-app snapshot row,
    /// so preserve the concrete rank before another app can push an unranked
    /// sibling to snapshot fallback. Background warmups must stay non-mutating.
    private func rememberFrontmostWindowFocusIfNeeded(in snapshot: [WindowItem]) {
        guard isSwitching,
              let frontmost = snapshot.first(where: \.isFrontmostApp),
              !frontmost.isApplicationFallback else { return }
        let sameAppWindowCount = snapshot.reduce(0) { count, item in
            count + (item.pid == frontmost.pid ? 1 : 0)
        }
        guard sameAppWindowCount > 1 else { return }
        PerformanceDiagnostics.$correlationID.withValue(lastReturnedSnapshotDiagnosticID) {
            PerformanceDiagnostics.record("focus_rank_decision", fields: [
                "open_id": .string(openDiagnosticID),
                "context": .string("switcher-open-focus"),
                "outcome": .string("accepted-first-frontmost-row"),
                "window_id": .int(Int(frontmost.id)),
                "pid": .int(Int(frontmost.pid))
            ])
            mruTracker.trackFocusedWindowActivation(frontmost, context: "switcher-open-focus")
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

        recordDisplayOrder(context: "stale-cache-refresh")

        previewLoadTask?.cancel()
        if showAfterRefresh {
            showWithPreviews()
        }
        return hydrateMs
    }

    private func schedulePreparedPanelShow() {
        cancelPanelShow()
        let delayNanoseconds = initialPanelShowDelayNanoseconds
        let scheduledAt = Date()
        let requestedAt = activeOpenRequestedAt
        let scheduleID = panelShowScheduleID
        let remainingDelayNanoseconds: UInt64
        if let requestedAt {
            let elapsedNanoseconds = UInt64(max(0, scheduledAt.timeIntervalSince(requestedAt) * 1_000_000_000))
            remainingDelayNanoseconds = elapsedNanoseconds >= delayNanoseconds
                ? 0
                : delayNanoseconds - elapsedNanoseconds
        } else {
            remainingDelayNanoseconds = delayNanoseconds
        }

        guard remainingDelayNanoseconds > 0 else {
            showPreparedPanelIfNeeded(
                scheduleID: scheduleID,
                scheduledAt: scheduledAt,
                requestedAt: requestedAt,
                expectedDelayNanoseconds: 0
            )
            return
        }

        // The quick-release grace window is anchored to the original hotkey
        // press, not to "snapshot finished". After a long idle pause, a
        // backgrounded agent's MainActor timer can wake hundreds of ms late;
        // a GCD main-queue timer avoids sharing the Swift concurrency executor
        // with SCKit capture tasks that can keep running after soft timeout.
        let delay = DispatchTimeInterval.nanoseconds(Int(remainingDelayNanoseconds))
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.showPreparedPanelIfNeeded(
                    scheduleID: scheduleID,
                    scheduledAt: scheduledAt,
                    requestedAt: requestedAt,
                    expectedDelayNanoseconds: remainingDelayNanoseconds
                )
            }
        }
        panelShowTimer = PanelShowTimer(workItem: workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func showPreparedPanelIfNeeded(
        scheduleID: Int? = nil,
        scheduledAt: Date? = nil,
        requestedAt: Date? = nil,
        expectedDelayNanoseconds: UInt64? = nil
    ) {
        if let scheduleID, scheduleID != panelShowScheduleID { return }
        guard case .previewHidden = phase else { return }
        panelShowTimer?.cancel()
        panelShowTimer = nil
        if let scheduledAt {
            var fields: [String: PerformanceMetricValue] = [
                "actual_wait_ms": .double(Date().timeIntervalSince(scheduledAt) * 1000)
            ]
            if let expectedDelayNanoseconds {
                fields["expected_wait_ms"] = .double(Double(expectedDelayNanoseconds) / 1_000_000)
            }
            if let requestedAt {
                fields["keydown_elapsed_ms"] = .double(Date().timeIntervalSince(requestedAt) * 1000)
            }
            PerformanceDiagnostics.record("panel_show_timer", fields: fields)
        }
        showWithPreviews()
    }

    private func cancelPanelShow() {
        panelShowTimer?.cancel()
        panelShowTimer = nil
        panelShowScheduleID += 1
    }

    func schedulePreviewCacheWarmup(context: String) {
        schedulePreviewCacheWarmup(context: context, delayNanoseconds: 0)
    }

    private func schedulePreviewCacheWarmup(context: String, delayNanoseconds: UInt64) {
        previewWarmupTask?.cancel()
        previewWarmupTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let self, !Task.isCancelled, !self.isVisible, !self.isSwitching else { return }
            await self.warmPreviewCache(context: context)
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
        let generation = settingsGeneration
        openItemsWarmupTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let self,
                  !Task.isCancelled,
                  self.settingsGeneration == generation,
                  !self.isVisible,
                  !self.isSwitching else { return }

            let start = Date()
            let visibleSnapshot = await self.snapshotVisibleOnlyOffMain()
            guard !Task.isCancelled,
                  self.settingsGeneration == generation,
                  !self.isVisible,
                  !self.isSwitching else { return }
            let orderedItems = self.orderItems(
                self.mruTracker.orderedForDisplay(
                    from: visibleSnapshot,
                    context: "open-items-warmup:\(context)",
                    snapshotDiagnosticID: self.lastReturnedSnapshotDiagnosticID
                )
            )
            guard !Task.isCancelled, !orderedItems.isEmpty else { return }
            let stabilizedItems = self.stabilizeBackgroundWarmupOrder(
                orderedItems,
                context: context,
                retainMissingCurrentAppWindows: true
            )
            let cacheItems = self.updateCachedOpenItems(stabilizedItems)
            let ms = Date().timeIntervalSince(start) * 1000
            if PerformanceLoggingState.mode != .off {
                Logger.switcher.info(
                    "Open-items cache warmup (\(context, privacy: .public)): \(cacheItems.count, privacy: .public) windows in \(ms, format: .fixed(precision: 1), privacy: .public) ms"
                )
            }
        }
    }

    private func stabilizeBackgroundWarmupOrder(
        _ orderedItems: [WindowItem],
        context: String,
        retainMissingCurrentAppWindows: Bool
    ) -> [WindowItem] {
        guard let frontmost = orderedItems.first else { return orderedItems }

        let cachedSameAppCount = cachedOpenItems.filter { $0.pid == frontmost.pid }.count
        guard cachedSameAppCount > 1 else { return orderedItems }

        let freshByID = Dictionary(orderedItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var usedIDs: Set<WindowItem.ID> = [frontmost.id]
        var stabilized: [WindowItem] = [frontmost]

        for cachedItem in cachedOpenItems where cachedItem.id != frontmost.id {
            if let fresh = freshByID[cachedItem.id] {
                guard usedIDs.insert(fresh.id).inserted else { continue }
                stabilized.append(fresh)
                continue
            }

            guard retainMissingCurrentAppWindows,
                  cachedItem.pid == frontmost.pid,
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
        if PerformanceDiagnostics.isEnabled, original.map(\.id) != stabilized.map(\.id) {
            let changeID = UUID().uuidString
            PerformanceDiagnostics.$correlationID.withValue(changeID) {
                PerformanceDiagnostics.recordWindowOrder("cache_stabilization", items: original, fields: [
                    "context": .string(context), "phase": .string("before")
                ])
                PerformanceDiagnostics.recordWindowOrder("cache_stabilization", items: stabilized, fields: [
                    "context": .string(context), "phase": .string("after")
                ])
            }
        }
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

    @discardableResult
    private func updateCachedOpenItems(_ orderedItems: [WindowItem]) -> [WindowItem] {
        let cacheItems = orderedItemsWithRememberedMinimizedItems(
            orderedItems,
            context: "cached-open-update"
        )
        cachedOpenItems = cacheItems
        PerformanceDiagnostics.recordWindowOrder("cache_order", items: cacheItems, fields: [
            "open_id": .string(openDiagnosticID)
        ])
        cachedOpenItemsUpdatedAt = cacheItems.isEmpty ? nil : Date()
        cachedOpenItemsNeedResnapshot = false
        primeHiddenDisplayItems(cacheItems)
        return cacheItems
    }

    private func updateCachedMinimizedItems(_ minimizedItems: [WindowItem]) {
        cachedMinimizedItems = minimizedItems
        cachedMinimizedItemsUpdatedAt = minimizedItems.isEmpty ? nil : Date()
    }

    private func freshCachedMinimizedItems(now: Date = Date()) -> [WindowItem] {
        guard let updatedAt = cachedMinimizedItemsUpdatedAt,
              now.timeIntervalSince(updatedAt) <= cachedOpenItemsMaxAge else {
            return []
        }
        return cachedMinimizedItems
    }

    private func orderedItemsWithRememberedMinimizedItems(
        _ orderedItems: [WindowItem],
        context: String
    ) -> [WindowItem] {
        let rememberedMinimizedItems = freshCachedMinimizedItems()
        guard !rememberedMinimizedItems.isEmpty else { return orderedItems }

        let rememberedMinimizedIDs = Set(rememberedMinimizedItems.map(\.id))
        let minimizedApplicationPIDs = Set(rememberedMinimizedItems.map(\.pid))
        let baseItems = orderedItems.filter { item in
            guard !rememberedMinimizedIDs.contains(item.id) else { return false }
            return !item.isApplicationFallback || !minimizedApplicationPIDs.contains(item.pid)
        }
        let existingIDs = Set(baseItems.map(\.id))
        let additions = rememberedMinimizedItems
            .filter { !existingIDs.contains($0.id) }
            .map { item in
                SwitchBladeSettings.shared.previewMode == .iconsOnly
                    ? item.withPreview(nil)
                    : previewCache.hydrated(item, liveItems: baseItems + rememberedMinimizedItems)
            }
        guard !additions.isEmpty || baseItems != orderedItems else { return orderedItems }

        return orderItems(
            mruTracker.orderedForDisplay(
                from: baseItems + additions,
                context: context
            )
        )
    }

    private func primeHiddenDisplayItems(_ orderedItems: [WindowItem]) {
        guard case .idle = phase, !orderedItems.isEmpty else { return }

        let hydratedItems = hydratedForDisplay(orderedItems)
        applyDisplayItems(hydratedItems, selectedID: defaultSelectedID(in: hydratedItems))
        onPreparePanel?(hydratedItems.count)
    }

    private func applyDisplayItems(_ newItems: [WindowItem], selectedID newSelectedID: WindowItem.ID?) {
        guard items != newItems || selectedID != newSelectedID else { return }

        // Disable animations so hidden warmup and visible open both land at the
        // final tile positions; navigation animations are only for explicit input.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            items = newItems
            selectedID = newSelectedID
        }
        recordDisplayOrder(context: "apply-items")
    }

    private func hiddenStaleCommitNeedsFreshSnapshot(for item: WindowItem) -> Bool {
        guard currentShowingStale else { return false }
        return items.filter { $0.pid == item.pid }.count > 1
    }

    private func deferHiddenStaleCommitUntilFreshSnapshot(_ item: WindowItem) {
        Logger.switcher.info(
            "Deferring hidden stale commit for same-app window id=\(item.id, privacy: .public) pid=\(item.pid, privacy: .public) until fresh snapshot"
        )
        cancelPanelShow()
        staleCacheHealTask?.cancel()
        staleCacheHealTask = nil
        openRefreshTask?.cancel()
        enterResolving(commitWhenReady: true)
        openFromFreshSnapshotOffMain()
    }

    private func logOpenOrdering(source: String, orderedItems: [WindowItem], selectedID: WindowItem.ID?) {
        PerformanceDiagnostics.recordWindowOrder("open_order", items: orderedItems, fields: [
            "open_id": .string(openDiagnosticID),
            "source": .string(source),
            "selected_id": .int(Int(selectedID ?? 0)),
            "stale": .bool(currentShowingStale)
        ])
        guard PerformanceLoggingState.mode == .debug else { return }
        let orderSummary = orderedItems.prefix(16)
            .enumerated()
            .map { index, item in
                let selected = item.id == selectedID ? "S" : "-"
                let frontmost = item.isFrontmostApp ? "F" : "-"
                return "\(index):id=\(item.id),pid=\(item.pid),front=\(frontmost),selected=\(selected)"
            }
            .joined(separator: ";")
        Logger.switcher.debug(
            "Open order source=\(source, privacy: .public) count=\(orderedItems.count, privacy: .public) selectedID=\(selectedID ?? 0, privacy: .public) staleVisible=\(self.currentShowingStale, privacy: .public) order=[\(orderSummary, privacy: .public)]"
        )
    }

    private func recordDisplayOrder(context: String) {
        PerformanceDiagnostics.recordWindowOrder(isVisible ? "display_order" : "prepared_order", items: items, fields: [
            "open_id": .string(openDiagnosticID),
            "context": .string(context),
            "source": .string(currentOpenSource ?? "unknown"),
            "selected_id": .int(Int(selectedID ?? 0)),
            "stale": .bool(currentShowingStale)
        ])
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

    private func cachedOpenItemsRequireFreshSnapshotForCurrentApp() -> Bool {
        guard let currentAppPID else { return false }
        return cachedOpenItems.filter { $0.pid == currentAppPID }.count > 1
    }

    private func recordPreviousSwitchDispatch(
        context: String,
        switchStart: Date,
        targetPID: pid_t,
        windowID: WindowItem.ID?
    ) {
        var fields: [String: PerformanceMetricValue] = [
            "context": .string(context),
            "dispatch_ms": .double(Date().timeIntervalSince(switchStart) * 1000),
            "pid": .int(Int(targetPID))
        ]
        if let windowID {
            fields["window_id"] = .int(Int(windowID))
        }
        PerformanceDiagnostics.record("previous_switch_dispatch", fields: fields)
    }

    @discardableResult
    private func markActivationRequest(
        pid: pid_t,
        context: String,
        source: String,
        windowID: WindowItem.ID?
    ) -> UUID {
        // A self-initiated focus change makes any pending external-activation
        // focus upgrade stale — let it die rather than have a delayed AX
        // resolve overwrite the rank the commit is about to record.
        focusedRankUpgradeTask?.cancel()
        pruneStaleActivationMeasurements(now: Date())
        let id = UUID()
        let measurement = PendingActivationMeasurement(
            id: id,
            requestedAt: Date(),
            context: context,
            source: source,
            windowID: windowID
        )
        pendingActivationMeasurements[pid, default: []].append(measurement)
        var fields: [String: PerformanceMetricValue] = [
            "context": .string(context),
            "pid": .int(Int(pid)),
            "source": .string(source)
        ]
        if let windowID {
            fields["window_id"] = .int(Int(windowID))
        }
        PerformanceDiagnostics.record("activation_request", fields: fields)
        return id
    }

    private func cancelActivationRequest(pid: pid_t, id: UUID) {
        guard var measurements = pendingActivationMeasurements[pid] else { return }
        measurements.removeAll { $0.id == id }
        pendingActivationMeasurements[pid] = measurements.isEmpty ? nil : measurements
    }

    /// Consumes and returns the oldest pending self-initiated activation for
    /// `pid`, or nil when the activation came from outside SwitchBlade.
    @discardableResult
    private func recordObservedActivationIfNeeded(pid: pid_t) -> PendingActivationMeasurement? {
        pruneStaleActivationMeasurements(now: Date())
        guard var measurements = pendingActivationMeasurements[pid],
              !measurements.isEmpty else { return nil }
        let measurement = measurements.removeFirst()
        pendingActivationMeasurements[pid] = measurements.isEmpty ? nil : measurements
        var fields: [String: PerformanceMetricValue] = [
            "context": .string(measurement.context),
            "latency_ms": .double(Date().timeIntervalSince(measurement.requestedAt) * 1000),
            "pid": .int(Int(pid)),
            "source": .string(measurement.source)
        ]
        if let windowID = measurement.windowID {
            fields["window_id"] = .int(Int(windowID))
        }
        PerformanceDiagnostics.record("activation_frontmost_observed", fields: fields)
        return measurement
    }

    /// System activation only names the app. Resolve the focused window via
    /// AX off-main and upgrade the identity-only rank to a concrete one —
    /// without this, windows of multi-window apps activated by click/Dock
    /// never gain per-window rank. The delay lets focus settle after the
    /// activation notification and coalesces rapid app switches to the last.
    private func scheduleFocusedWindowRankUpgrade(pid: pid_t) {
        focusedRankUpgradeTask?.cancel()
        let catalog = self.catalog
        let delayNanoseconds = focusedRankUpgradeDelayNanoseconds
        let diagnosticID = UUID().uuidString
        PerformanceDiagnostics.$correlationID.withValue(diagnosticID) {
            PerformanceDiagnostics.record("focus_rank_scheduled", fields: [
                "pid": .int(Int(pid)), "context": .string("system-activation-focus")
            ])
        }
        focusedRankUpgradeTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let self, !Task.isCancelled else {
                PerformanceDiagnostics.$correlationID.withValue(diagnosticID) {
                    PerformanceDiagnostics.record("focus_rank_decision", fields: [
                        "pid": .int(Int(pid)), "context": .string("system-activation-focus"),
                        "outcome": .string("discarded-before-probe")
                    ])
                }
                return
            }
            guard self.currentAppPID == pid, !self.isVisible, !self.isSwitching else {
                self.recordFocusRankDecision(item: nil, diagnosticID: diagnosticID,
                    context: "system-activation-focus", outcome: "discarded-state-before-probe")
                return
            }
            let item = await Task.detached(priority: .utility) {
                Self.diagnosticFocusedWindow(catalog: catalog, pid: pid, diagnosticID: diagnosticID,
                                             context: "system-activation-focus")
            }.value
            guard !Task.isCancelled, let item, item.pid == pid else {
                self.recordFocusRankDecision(item: item, diagnosticID: diagnosticID,
                    context: "system-activation-focus", outcome: Task.isCancelled ? "discarded-cancelled" : "discarded-unresolved")
                return
            }
            guard self.currentAppPID == pid, !self.isVisible, !self.isSwitching else {
                self.recordFocusRankDecision(item: item, diagnosticID: diagnosticID,
                    context: "system-activation-focus", outcome: "discarded-state-changed")
                return
            }
            self.recordFocusRankDecision(item: item, diagnosticID: diagnosticID,
                context: "system-activation-focus", outcome: "accepted")
            self.mruTracker.trackFocusedWindowActivation(item)
        }
    }

    /// Resolve the exact window the previous app left focused. A newly-created
    /// sibling can be absent from the young open-items cache, so waiting for a
    /// background warmup would discover it only as an unranked snapshot
    /// fallback. AX retains the focused window after the app backgrounds; the
    /// result is accepted only while the same successor app is still current.
    private func scheduleBackgroundedWindowRankUpgrade(pid: pid_t, expectedCurrentPID: pid_t) {
        backgroundedFocusRankTask?.cancel()
        let catalog = self.catalog
        let diagnosticID = UUID().uuidString
        backgroundedFocusRankTask = Task { @MainActor [weak self] in
            let item = await Task.detached(priority: .utility) {
                Self.diagnosticFocusedWindow(catalog: catalog, pid: pid, diagnosticID: diagnosticID,
                                             context: "backgrounded-app-focus")
            }.value
            guard let self else { return }
            guard !Task.isCancelled, self.currentAppPID == expectedCurrentPID, !self.isVisible, !self.isSwitching else {
                self.recordFocusRankDecision(item: item, diagnosticID: diagnosticID,
                    context: "backgrounded-app-focus", outcome: Task.isCancelled ? "discarded-cancelled" : "discarded-state-changed")
                return
            }
            guard let item, item.pid == pid, !item.isApplicationFallback else {
                self.recordFocusRankDecision(item: item, diagnosticID: diagnosticID,
                    context: "backgrounded-app-focus", outcome: "discarded-unresolved")
                return
            }
            self.recordFocusRankDecision(item: item, diagnosticID: diagnosticID,
                context: "backgrounded-app-focus", outcome: "accepted")
            self.mruTracker.trackBackgroundedWindowFocus(item)
        }
    }

    private nonisolated static func diagnosticFocusedWindow(
        catalog: WindowSnapshotProviding, pid: pid_t, diagnosticID: String, context: String
    ) -> WindowItem? {
        PerformanceDiagnostics.$correlationID.withValue(diagnosticID) {
            PerformanceDiagnostics.$context.withValue(context) {
                let item = catalog.focusedWindowItem(pid: pid)
                PerformanceDiagnostics.record("focus_probe_result", fields: [
                    "pid": .int(Int(pid)), "window_id": .int(Int(item?.id ?? 0)),
                    "resolved": .bool(item != nil)
                ])
                return item
            }
        }
    }

    private func recordFocusRankDecision(item: WindowItem?, diagnosticID: String, context: String, outcome: String) {
        PerformanceDiagnostics.$correlationID.withValue(diagnosticID) {
            PerformanceDiagnostics.record("focus_rank_decision", fields: [
                "open_id": .string(openDiagnosticID), "context": .string(context),
                "outcome": .string(outcome), "window_id": .int(Int(item?.id ?? 0)),
                "pid": .int(Int(item?.pid ?? -1)), "current_pid": .int(Int(currentAppPID ?? -1))
            ])
        }
    }

    private func pruneStaleActivationMeasurements(now: Date) {
        for (pid, measurements) in pendingActivationMeasurements {
            let freshMeasurements = measurements.filter { now.timeIntervalSince($0.requestedAt) <= 5 }
            pendingActivationMeasurements[pid] = freshMeasurements.isEmpty ? nil : freshMeasurements
        }
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
            let items = await inFlightVisibleSnapshot.task.value
            recordReturnedSnapshot(inFlightVisibleSnapshot, coalesced: true)
            return items
        }

        let catalog = self.catalog
        let diagnosticID = UUID().uuidString
        let inFlightVisibleSnapshot = InFlightVisibleSnapshot(
            diagnosticID: diagnosticID,
            task: Task.detached(priority: priority) {
                PerformanceDiagnostics.$correlationID.withValue(diagnosticID) {
                    catalog.snapshotVisibleOnly()
                }
            }
        )
        self.inFlightVisibleSnapshot = inFlightVisibleSnapshot
        let visibleItems = await inFlightVisibleSnapshot.task.value
        if self.inFlightVisibleSnapshot === inFlightVisibleSnapshot {
            self.inFlightVisibleSnapshot = nil
        }
        recordReturnedSnapshot(inFlightVisibleSnapshot, coalesced: false)
        return visibleItems
    }

    private func recordReturnedSnapshot(_ snapshot: InFlightVisibleSnapshot, coalesced: Bool) {
        // Main-actor callers inspect/rank the returned array synchronously
        // before their next suspension, including coalesced consumers.
        lastReturnedSnapshotDiagnosticID = snapshot.diagnosticID
        PerformanceDiagnostics.$correlationID.withValue(snapshot.diagnosticID) {
            PerformanceDiagnostics.record("snapshot_returned", fields: [
                "open_id": .string(openDiagnosticID),
                "coalesced": .bool(coalesced),
                "switching": .bool(isSwitching),
                "visible": .bool(isVisible)
            ])
        }
    }

    private func showWithPreviews() {
        cancelPanelShow()
        // Carry the incoming display staleness (from .previewHidden / .resolving)
        // into the visible phase below.
        let stale = currentShowingStale
        let shouldShowPanel = !isVisible
        guard SwitchBladeSettings.shared.previewMode != .iconsOnly else {
            previewGeneration += 1
            let generation = previewGeneration
            hoverEnabled = false
            enterVisible(stale: stale)
            schedulePanelShow(generation: generation, shouldShowPanel: shouldShowPanel)
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
            schedulePanelShow(generation: generation, shouldShowPanel: shouldShowPanel)
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
        schedulePanelShow(generation: generation, shouldShowPanel: shouldShowPanel)
        scheduleHoverEnable(generation: generation)
        scheduleMinimizedMerge()

        previewLoadTask = Task {
            let batchStart = Date()
            var previews: [CGWindowID: NSImage] = [:]
            let firstBatchWindowIDs = priorityWindowIDs
            if !firstBatchWindowIDs.isEmpty {
                let batchPreviews = await catalog.capturePreviews(
                    for: firstBatchWindowIDs,
                    maxCount: nil,
                    maxConcurrentCaptures: min(4, firstBatchWindowIDs.count),
                    allowedOffscreenWindowIDs: []
                )
                guard !Task.isCancelled else { return }
                previews.merge(batchPreviews) { _, fresh in fresh }
                await self.applyPreviews(batchPreviews, generation: generation)
            }

            guard !Task.isCancelled else { return }
            let firstBatchMs = Date().timeIntervalSince(batchStart) * 1000
            let successRate = firstBatchWindowIDs.isEmpty ? 0
                : Double(previews.count) / Double(firstBatchWindowIDs.count)
            let batchSummary = self.performanceMetrics.recordFirstPreviewBatch(milliseconds: firstBatchMs)
            PerformanceDiagnostics.record(
                "first_preview_batch",
                fields: [
                    "captured": .int(previews.count),
                    "initial_requested": .int(firstBatchWindowIDs.count),
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

            let failedFirstBatchWindowIDs = firstBatchWindowIDs.filter { previews[$0] == nil }
            let followUpInitialWindowIDs = Self.uniqueWindowIDs(
                failedFirstBatchWindowIDs + remainingInitialWindowIDs
            )
            if !followUpInitialWindowIDs.isEmpty {
                let followUpPreviews = await catalog.capturePreviews(
                    for: followUpInitialWindowIDs,
                    maxCount: nil,
                    maxConcurrentCaptures: min(4, followUpInitialWindowIDs.count),
                    allowedOffscreenWindowIDs: []
                )
                guard !Task.isCancelled else { return }
                previews.merge(followUpPreviews) { _, fresh in fresh }
                await self.applyPreviews(followUpPreviews, generation: generation)
            }

            let firstBatchWindowIDSet = Set(firstBatchWindowIDs)
            let initialWindowIDSet = Set(initialWindowIDs)
            let uncachedDeferredWindowIDs = self.items.compactMap { item -> CGWindowID? in
                guard !item.isMinimized,
                      item.canCapturePreview,
                      item.preview == nil,
                      !firstBatchWindowIDSet.contains(item.windowID),
                      !initialWindowIDSet.contains(item.windowID) else {
                    return nil
                }
                return item.windowID
            }
            let deferredCandidates = uncachedDeferredWindowIDs
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
                    maxConcurrentCaptures: 6,
                    allowedOffscreenWindowIDs: []
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

    private static func uniqueWindowIDs(_ windowIDs: [CGWindowID]) -> [CGWindowID] {
        var seen: Set<CGWindowID> = []
        return windowIDs.filter { seen.insert($0).inserted }
    }

    private func applyPreviews(_ previews: [CGWindowID: NSImage], generation: Int) async {
        guard isVisible, previewGeneration == generation else { return }
        // Classify blank frames off the main thread, then re-check the
        // generation: the panel may have hidden or reopened during the decode.
        let classifications = await PreviewCacheStore.classifyCapturedFrames(previews)
        guard isVisible, previewGeneration == generation else { return }
        recordRejectedBlackFrames(classifications)
        let acceptedPreviews = previewCache.record(
            previews,
            liveItems: items,
            classifications: classifications
        )
        items = items.map { item in
            acceptedPreviews[item.windowID].map { item.withPreview($0) } ?? item
        }
    }

    private func recordRejectedBlackFrames(_ classifications: PreviewFrameClassifications) {
        let rejectedCount = classifications.uniformlyBlackIDs.count
        guard rejectedCount > 0 else { return }
        Logger.capture.notice(
            "Rejected \(rejectedCount, privacy: .public) uniformly black preview frame(s)"
        )
        PerformanceDiagnostics.record(
            "preview_frame_validation",
            fields: ["uniformly_black_rejected": .int(rejectedCount)]
        )
    }

    /// Lazily fetch minimized windows off the main thread and merge them in.
    /// The AX walk is ~150–500 ms with many apps — running it inline would
    /// block the panel from appearing. Called from `showWithPreviews` so the
    /// captured `previewGeneration` matches the just-incremented value the
    /// eventual merge-guard checks against.
    private func scheduleMinimizedMerge() {
        let mergeGeneration = previewGeneration
        let catalog = self.catalog
        let cancellation = CooperativeCancellationToken()
        minimizedMergeTask?.cancel()
        minimizedMergeTask = Task(priority: .userInitiated) { [weak self] in
            await withTaskCancellationHandler {
                let minimizedSnapshot = await catalog.snapshotMinimized(cancellation: cancellation)
                guard !Task.isCancelled, !cancellation.isCancelled else { return }
                guard minimizedSnapshot.isComplete else { return }
                let previewWindowIDs = self?.mergeMinimizedItems(
                    minimizedSnapshot.items,
                    generation: mergeGeneration
                ) ?? []
                guard !Task.isCancelled,
                      !cancellation.isCancelled,
                      !previewWindowIDs.isEmpty else { return }
                let previews = await catalog.capturePreviews(
                    for: previewWindowIDs,
                    maxCount: nil,
                    maxConcurrentCaptures: min(4, previewWindowIDs.count),
                    allowedOffscreenWindowIDs: Set(previewWindowIDs)
                )
                guard !Task.isCancelled, !cancellation.isCancelled else { return }
                await self?.applyPreviews(previews, generation: mergeGeneration)
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    private func mergeMinimizedItems(_ minimized: [WindowItem], generation: Int) -> [CGWindowID] {
        guard isVisible, previewGeneration == generation else { return [] }
        updateCachedMinimizedItems(minimized)
        let previousSelectedID = selectedID
        let selectionWasDefault = previousSelectedID == defaultSelectedID(in: items)
        let minimizedIDs = Set(minimized.map(\.id))
        let minimizedApplicationPIDs = Set(minimized.map(\.pid))
        let visibleItems = items.filter { item in
            guard !item.isMinimized, !minimizedIDs.contains(item.id) else { return false }
            return !item.isApplicationFallback || !minimizedApplicationPIDs.contains(item.pid)
        }
        let minimizedItems = minimized.map { item in
            SwitchBladeSettings.shared.previewMode == .iconsOnly
                ? item
                : previewCache.hydrated(item, liveItems: visibleItems + minimized)
        }
        let mergedItems = visibleItems + minimizedItems
        guard !mergedItems.isEmpty else { return [] }
        let orderedItems = orderItems(
            mruTracker.orderedForDisplay(
                from: mergedItems,
                context: "minimized-merge"
            )
        )
        updateCachedOpenItems(orderedItems)
        let minimizedPreviewCandidates = SwitchBladeSettings.shared.previewMode == .iconsOnly
            ? []
            : orderedItems.compactMap { item -> CGWindowID? in
                guard item.isMinimized,
                      item.canCapturePreview,
                      !item.isTitleRedacted,
                      !item.isApplicationFallback,
                      !SyntheticWindowID.isSynthetic(item.windowID),
                      item.preview == nil else {
                    return nil
                }
                return item.windowID
            }
        let minimizedPreviewWindowIDs = Array(
            minimizedPreviewCandidates.prefix(deferredPreviewCaptureBudget)
        )
        if PerformanceLoggingState.mode == .debug, !minimizedPreviewCandidates.isEmpty {
            PerformanceDiagnostics.record(
                "minimized_preview_selection",
                fields: [
                    "budget": .int(deferredPreviewCaptureBudget),
                    "candidates": .int(minimizedPreviewCandidates.count),
                    "scheduled": .int(minimizedPreviewWindowIDs.count)
                ]
            )
        }
        guard orderedItems != items else { return minimizedPreviewWindowIDs }
        items = orderedItems
        if selectionWasDefault {
            selectedID = defaultSelectedID(in: orderedItems)
        } else if let previousSelectedID,
                  orderedItems.contains(where: { $0.id == previousSelectedID }) {
            selectedID = previousSelectedID
        } else {
            selectedID = defaultSelectedID(in: orderedItems)
        }
        recordDisplayOrder(context: "minimized-merge")
        return minimizedPreviewWindowIDs
    }

    private func scheduleHoverEnable(generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, self.previewGeneration == generation else { return }
            self.hoverEnabled = true
        }
    }

    private func schedulePanelShow(generation: Int, shouldShowPanel: Bool) {
        guard isVisible, previewGeneration == generation else { return }
        guard shouldShowPanel else { return }
        onShow?()
        recordDisplayOrder(context: "panel-show")
        recordPanelVisibleMetric(itemCount: items.count)
    }

    private func removeItem(withID id: WindowItem.ID) {
        defer { recordDisplayOrder(context: "close") }
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
