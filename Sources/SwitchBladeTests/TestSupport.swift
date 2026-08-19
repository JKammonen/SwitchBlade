import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
@testable import SwitchBladeCore

// MARK: - WindowItem factory

/// Builds a WindowItem with sensible defaults so test bodies stay short.
func makeItem(
    id: CGWindowID,
    pid: pid_t = 100,
    appName: String = "TestApp",
    title: String = "Window",
    isFrontmostApp: Bool = false,
    isMinimized: Bool = false,
    canCapturePreview: Bool = true,
    isTitleRedacted: Bool = false,
    bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
    bundleIdentifier: String? = nil,
    windowOwnerPID: pid_t? = nil
) -> WindowItem {
    WindowItem(
        windowID: id,
        pid: pid,
        appName: appName,
        title: title,
        bounds: bounds,
        isFrontmostApp: isFrontmostApp,
        isMinimized: isMinimized,
        canCapturePreview: canCapturePreview,
        isTitleRedacted: isTitleRedacted,
        preview: nil,
        icon: nil,
        bundleIdentifier: bundleIdentifier,
        windowOwnerPID: windowOwnerPID
    )
}

// MARK: - Mocks

final class MockWindowCatalog: WindowSnapshotProviding, @unchecked Sendable {
    var visibleItems: [WindowItem] = []
    var minimizedItems: [WindowItem] = []
    var previewsToReturn: [CGWindowID: NSImage] = [:]
    var visibleSnapshotDelayNanoseconds: UInt64 = 0
    var minimizedSnapshotDelayNanoseconds: UInt64 = 0

    private let lock = NSLock()
    private var _visibleSnapshotCount = 0
    private var _minimizedSnapshotCount = 0
    private var _minimizedSnapshotStartCount = 0
    private var _minimizedSnapshotCancellationCount = 0
    private var _captureCallCount = 0
    private var _lastCaptureWindowIDs: [CGWindowID] = []
    private var _captureWindowIDCalls: [[CGWindowID]] = []
    private var _allowedOffscreenWindowIDCalls: [Set<CGWindowID>] = []
    private var _refreshCallCount = 0

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var visibleSnapshotCount: Int { withLock { _visibleSnapshotCount } }
    var minimizedSnapshotCount: Int { withLock { _minimizedSnapshotCount } }
    var minimizedSnapshotStartCount: Int { withLock { _minimizedSnapshotStartCount } }
    var minimizedSnapshotCancellationCount: Int { withLock { _minimizedSnapshotCancellationCount } }
    var captureCallCount: Int { withLock { _captureCallCount } }
    var lastCaptureWindowIDs: [CGWindowID] { withLock { _lastCaptureWindowIDs } }
    var captureWindowIDCalls: [[CGWindowID]] { withLock { _captureWindowIDCalls } }
    var allowedOffscreenWindowIDCalls: [Set<CGWindowID>] { withLock { _allowedOffscreenWindowIDCalls } }
    var refreshCallCount: Int { withLock { _refreshCallCount } }

    func snapshotVisibleOnly() -> [WindowItem] {
        withLock { _visibleSnapshotCount += 1 }
        let snapshot = visibleItems
        if visibleSnapshotDelayNanoseconds > 0 {
            Thread.sleep(forTimeInterval: Double(visibleSnapshotDelayNanoseconds) / 1_000_000_000)
        }
        return snapshot
    }

    func snapshotMinimized(cancellation: CooperativeCancellationToken) async -> [WindowItem] {
        withLock { _minimizedSnapshotStartCount += 1 }
        var remainingDelay = minimizedSnapshotDelayNanoseconds
        while remainingDelay > 0 {
            if cancellation.isCancelled {
                withLock { _minimizedSnapshotCancellationCount += 1 }
                return []
            }
            let slice = min(remainingDelay, 5_000_000)
            try? await Task.sleep(nanoseconds: slice)
            remainingDelay -= slice
        }
        if cancellation.isCancelled {
            withLock { _minimizedSnapshotCancellationCount += 1 }
            return []
        }
        withLock { _minimizedSnapshotCount += 1 }
        return minimizedItems
    }

    func capturePreviews(
        for windowIDs: [CGWindowID],
        maxCount: Int?,
        maxConcurrentCaptures: Int,
        allowedOffscreenWindowIDs: Set<CGWindowID>
    ) async -> [CGWindowID: NSImage] {
        let requestedIDs = maxCount.map { Array(windowIDs.prefix($0)) } ?? windowIDs
        withLock {
            _captureCallCount += 1
            _lastCaptureWindowIDs = requestedIDs
            _captureWindowIDCalls.append(requestedIDs)
            _allowedOffscreenWindowIDCalls.append(allowedOffscreenWindowIDs.intersection(requestedIDs))
        }
        let requestedSet = Set(requestedIDs)
        return previewsToReturn.filter { requestedSet.contains($0.key) }
    }

    func refreshContentCache() async {
        withLock { _refreshCallCount += 1 }
    }

    private var _refreshIfStaleCallCount = 0
    var refreshIfStaleCallCount: Int { withLock { _refreshIfStaleCallCount } }
    func refreshContentCacheIfStale() async {
        withLock { _refreshIfStaleCallCount += 1 }
    }

    private var _invalidateContentCacheCallCount = 0
    private var _lastInvalidationReason: String?
    var invalidateContentCacheCallCount: Int { withLock { _invalidateContentCacheCallCount } }
    var lastInvalidationReason: String? { withLock { _lastInvalidationReason } }
    func invalidateContentCache(reason: String) async {
        withLock {
            _invalidateContentCacheCallCount += 1
            _lastInvalidationReason = reason
        }
    }

    var focusedWindowItemsByPID: [pid_t: WindowItem] = [:]
    private var _focusedWindowItemCallCount = 0
    var focusedWindowItemCallCount: Int { withLock { _focusedWindowItemCallCount } }
    func focusedWindowItem(pid: pid_t) -> WindowItem? {
        withLock { _focusedWindowItemCallCount += 1 }
        return focusedWindowItemsByPID[pid]
    }
}

final class MockWindowActivator: WindowActivating, @unchecked Sendable {
    struct SnapCall: Equatable {
        let id: CGWindowID
        let edge: WindowSnapEdge
    }

    private struct State {
        var activatedItems: [WindowActionTarget] = []
        var activatedApplicationPIDs: [pid_t] = []
        var reopenedApplicationPIDs: [pid_t] = []
        var snapCalls: [SnapCall] = []
        var closedItems: [WindowActionTarget] = []
        var quitItems: [WindowActionTarget] = []
        var hiddenItems: [WindowActionTarget] = []
        var closeSucceeds = true
        var snapSucceeds = true
        var activationSucceeds = true
        var applicationActivationSucceeds = true
        var quitSucceeds = true
        var hideSucceeds = true
        var actionDelayNanoseconds: UInt64 = 0
    }

    private let state = LockedValue(State())
    var activatedItems: [WindowActionTarget] { state.value.activatedItems }
    var activatedApplicationPIDs: [pid_t] { state.value.activatedApplicationPIDs }
    var reopenedApplicationPIDs: [pid_t] { state.value.reopenedApplicationPIDs }
    var snapCalls: [SnapCall] { state.value.snapCalls }
    var closedItems: [WindowActionTarget] { state.value.closedItems }
    var quitItems: [WindowActionTarget] { state.value.quitItems }
    var hiddenItems: [WindowActionTarget] { state.value.hiddenItems }
    var closeSucceeds: Bool {
        get { state.value.closeSucceeds }
        set { state.withValue { $0.closeSucceeds = newValue } }
    }
    var snapSucceeds: Bool {
        get { state.value.snapSucceeds }
        set { state.withValue { $0.snapSucceeds = newValue } }
    }
    var activationSucceeds: Bool {
        get { state.value.activationSucceeds }
        set { state.withValue { $0.activationSucceeds = newValue } }
    }
    var applicationActivationSucceeds: Bool {
        get { state.value.applicationActivationSucceeds }
        set { state.withValue { $0.applicationActivationSucceeds = newValue } }
    }
    var quitSucceeds: Bool {
        get { state.value.quitSucceeds }
        set { state.withValue { $0.quitSucceeds = newValue } }
    }
    var hideSucceeds: Bool {
        get { state.value.hideSucceeds }
        set { state.withValue { $0.hideSucceeds = newValue } }
    }
    var actionDelayNanoseconds: UInt64 {
        get { state.value.actionDelayNanoseconds }
        set { state.withValue { $0.actionDelayNanoseconds = newValue } }
    }

    private func delayIfNeeded() {
        let delay = state.value.actionDelayNanoseconds
        if delay > 0 {
            Thread.sleep(forTimeInterval: Double(delay) / 1_000_000_000)
        }
    }

    func activate(_ item: WindowActionTarget) -> Bool {
        delayIfNeeded()
        return state.withValue {
            $0.activatedItems.append(item)
            return $0.activationSucceeds
        }
    }
    func activateApplication(pid: pid_t) -> Bool {
        delayIfNeeded()
        return state.withValue {
            $0.activatedApplicationPIDs.append(pid)
            return $0.applicationActivationSucceeds
        }
    }
    func reopenApplication(pid: pid_t) -> Bool {
        delayIfNeeded()
        return state.withValue {
            $0.reopenedApplicationPIDs.append(pid)
            return $0.applicationActivationSucceeds
        }
    }
    func snap(_ item: WindowActionTarget, to edge: WindowSnapEdge) -> Bool {
        delayIfNeeded()
        return state.withValue {
            $0.snapCalls.append(SnapCall(id: item.id, edge: edge))
            return $0.snapSucceeds
        }
    }
    func close(_ item: WindowActionTarget) -> Bool {
        delayIfNeeded()
        return state.withValue {
            $0.closedItems.append(item)
            return $0.closeSucceeds
        }
    }
    func quit(_ item: WindowActionTarget) -> Bool {
        delayIfNeeded()
        return state.withValue {
            $0.quitItems.append(item)
            return $0.quitSucceeds
        }
    }
    func hide(_ item: WindowActionTarget) -> Bool {
        delayIfNeeded()
        return state.withValue {
            $0.hiddenItems.append(item)
            return $0.hideSucceeds
        }
    }
}

final class MockPermissionService: PermissionProviding, @unchecked Sendable {
    var state = PermissionState(hasAccessibility: true, hasScreenRecording: true)
    func currentState() -> PermissionState { state }
}

// MARK: - Factories

@MainActor
func makeStore(
    catalog: MockWindowCatalog = MockWindowCatalog(),
    activator: MockWindowActivator = MockWindowActivator(),
    permissions: MockPermissionService = MockPermissionService(),
    userDefaults: UserDefaults = makeIsolatedUserDefaults(),
    mruTracker: MRUTracker? = nil,
    activationWarmupWindow: TimeInterval = 60,
    cachedOpenItemsMaxAge: TimeInterval = 30,
    initialPanelShowDelayNanoseconds: UInt64 = 0,
    deferredPreviewCaptureBudget: Int = 12,
    focusedRankUpgradeDelayNanoseconds: UInt64 = 0,
    initialFrontmostAppPID: pid_t? = nil,
    switchBladePID: pid_t = getpid()
) -> (SwitcherStore, MockWindowCatalog, MockWindowActivator, MockPermissionService) {
    let store = SwitcherStore(
        catalog: catalog,
        activator: activator,
        permissionService: permissions,
        userDefaults: userDefaults,
        mruTracker: mruTracker,
        activationWarmupWindow: activationWarmupWindow,
        cachedOpenItemsMaxAge: cachedOpenItemsMaxAge,
        initialPanelShowDelayNanoseconds: initialPanelShowDelayNanoseconds,
        deferredPreviewCaptureBudget: deferredPreviewCaptureBudget,
        focusedRankUpgradeDelayNanoseconds: focusedRankUpgradeDelayNanoseconds,
        initialFrontmostAppPID: initialFrontmostAppPID,
        switchBladePID: switchBladePID
    )
    return (store, catalog, activator, permissions)
}

/// Per-test isolated UserDefaults — avoids cross-test pollution and stale
/// MRU bleed-through from real app launches on the same machine.
func makeIsolatedUserDefaults() -> UserDefaults {
    let suite = "switchblade.tests.\(UUID().uuidString)"
    let ud = UserDefaults(suiteName: suite)!
    ud.removePersistentDomain(forName: suite)
    return ud
}

/// Yield to MainActor, then wait one frame so deferred selection actions run.
@MainActor
func runPendingMainTasks(_ iterations: Int = 8) async {
    for _ in 0 ..< iterations {
        await Task.yield()
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0 ..< iterations {
        await Task.yield()
    }
}

/// Opens the switcher through the production async path (`requestCycle`) and
/// waits for the panel to become visible. Replaces the old synchronous
/// `cycle()`-to-open shortcut, which exercised a code path production never hits.
/// Polls so it works whether the store defers the panel show or not.
@MainActor
func openSwitcher(_ store: SwitcherStore, forward: Bool = true) async {
    store.requestCycle(forward: forward)
    await runPendingMainTasks()
    for _ in 0 ..< 60 where !store.isVisible {
        try? await Task.sleep(nanoseconds: 5_000_000)
        await Task.yield()
    }
    await runPendingMainTasks()
}

/// Populates `cachedOpenItems` the way a real open + dismiss would (one visible
/// snapshot), then hides — without waiting for the panel to show. Use to seed the
/// cache before a requestCycle test. Replaces the old `cycle(); cancel()` seed.
@MainActor
func seedOpenItemsCache(_ store: SwitcherStore, forward: Bool = true) async {
    store.requestCycle(forward: forward)
    await runPendingMainTasks()
    store.cancel()
    await runPendingMainTasks()
}

// MARK: - NSEvent factory

@MainActor
func makeKeyDownEvent(
    keyCode: Int,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: UInt16(keyCode)
    )!
}
