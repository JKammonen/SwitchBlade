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

    private(set) var visibleSnapshotCount = 0
    private(set) var minimizedSnapshotCount = 0
    private(set) var captureCallCount = 0
    private(set) var lastCaptureWindowIDs: [CGWindowID] = []
    private(set) var refreshCallCount = 0

    func snapshotVisibleOnly() -> [WindowItem] {
        visibleSnapshotCount += 1
        return visibleItems
    }

    func snapshotMinimized() async -> [WindowItem] {
        minimizedSnapshotCount += 1
        return minimizedItems
    }

    func capturePreviews(
        for windowIDs: [CGWindowID],
        maxCount: Int?,
        maxConcurrentCaptures: Int
    ) async -> [CGWindowID: NSImage] {
        captureCallCount += 1
        lastCaptureWindowIDs = windowIDs
        return previewsToReturn
    }

    func refreshContentCache() async {
        refreshCallCount += 1
    }
}

final class MockWindowActivator: WindowActivating, @unchecked Sendable {
    private(set) var activatedItems: [WindowItem] = []
    private(set) var closedItems: [WindowItem] = []
    private(set) var quitItems: [WindowItem] = []
    private(set) var hiddenItems: [WindowItem] = []

    func activate(_ item: WindowItem) { activatedItems.append(item) }
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
    userDefaults: UserDefaults = makeIsolatedUserDefaults()
) -> (SwitcherStore, MockWindowCatalog, MockWindowActivator, MockPermissionService) {
    let store = SwitcherStore(
        catalog: catalog,
        activator: activator,
        permissionService: permissions,
        userDefaults: userDefaults
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
