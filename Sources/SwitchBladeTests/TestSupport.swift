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
    bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
    bundleIdentifier: String? = nil
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
        preview: nil,
        icon: nil,
        bundleIdentifier: bundleIdentifier
    )
}

// MARK: - Mocks

final class MockWindowCatalog: WindowSnapshotProviding, @unchecked Sendable {
    var visibleItems: [WindowItem] = []
    var minimizedItems: [WindowItem] = []
    var previewsToReturn: [CGWindowID: NSImage] = [:]

    private let lock = NSLock()
    private var _visibleSnapshotCount = 0
    private var _minimizedSnapshotCount = 0
    private var _captureCallCount = 0
    private var _lastCaptureWindowIDs: [CGWindowID] = []
    private var _captureWindowIDCalls: [[CGWindowID]] = []
    private var _refreshCallCount = 0

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var visibleSnapshotCount: Int { withLock { _visibleSnapshotCount } }
    var minimizedSnapshotCount: Int { withLock { _minimizedSnapshotCount } }
    var captureCallCount: Int { withLock { _captureCallCount } }
    var lastCaptureWindowIDs: [CGWindowID] { withLock { _lastCaptureWindowIDs } }
    var captureWindowIDCalls: [[CGWindowID]] { withLock { _captureWindowIDCalls } }
    var refreshCallCount: Int { withLock { _refreshCallCount } }

    func snapshotVisibleOnly() -> [WindowItem] {
        withLock { _visibleSnapshotCount += 1 }
        return visibleItems
    }

    func snapshotMinimized() async -> [WindowItem] {
        withLock { _minimizedSnapshotCount += 1 }
        return minimizedItems
    }

    func capturePreviews(
        for windowIDs: [CGWindowID],
        maxCount: Int?,
        maxConcurrentCaptures: Int
    ) async -> [CGWindowID: NSImage] {
        let requestedIDs = maxCount.map { Array(windowIDs.prefix($0)) } ?? windowIDs
        withLock {
            _captureCallCount += 1
            _lastCaptureWindowIDs = requestedIDs
            _captureWindowIDCalls.append(requestedIDs)
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
}

final class MockWindowActivator: WindowActivating, @unchecked Sendable {
    struct SnapCall: Equatable {
        let id: CGWindowID
        let edge: WindowSnapEdge
    }

    private(set) var activatedItems: [WindowItem] = []
    private(set) var activatedApplicationPIDs: [pid_t] = []
    private(set) var snapCalls: [SnapCall] = []
    private(set) var closedItems: [WindowItem] = []
    private(set) var quitItems: [WindowItem] = []
    private(set) var hiddenItems: [WindowItem] = []

    func activate(_ item: WindowItem) { activatedItems.append(item) }
    func activateApplication(pid: pid_t) { activatedApplicationPIDs.append(pid) }
    func snap(_ item: WindowItem, to edge: WindowSnapEdge) -> Bool {
        snapCalls.append(SnapCall(id: item.id, edge: edge))
        return true
    }
    func close(_ item: WindowItem)    { closedItems.append(item) }
    func quit(_ item: WindowItem)     { quitItems.append(item) }
    func hide(_ item: WindowItem)     { hiddenItems.append(item) }
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
    activationWarmupWindow: TimeInterval = 60,
    initialFrontmostAppPID: pid_t? = nil,
    switchBladePID: pid_t = getpid()
) -> (SwitcherStore, MockWindowCatalog, MockWindowActivator, MockPermissionService) {
    let store = SwitcherStore(
        catalog: catalog,
        activator: activator,
        permissionService: permissions,
        userDefaults: userDefaults,
        activationWarmupWindow: activationWarmupWindow,
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

/// Yield to MainActor a few times so deferred Task { @MainActor in } work runs.
@MainActor
func runPendingMainTasks(_ iterations: Int = 8) async {
    for _ in 0 ..< iterations {
        await Task.yield()
    }
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
