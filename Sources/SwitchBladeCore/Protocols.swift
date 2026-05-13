import AppKit
import CoreGraphics

/// Window-listing dependency for SwitcherStore. Concrete WindowCatalog conforms;
/// tests inject a mock to drive snapshot contents without touching real CGWindow
/// or ScreenCaptureKit APIs.
protocol WindowSnapshotProviding: Sendable {
    func snapshotVisibleOnly() -> [WindowItem]
    func snapshotMinimized() async -> [WindowItem]
    func capturePreviews(
        for windowIDs: [CGWindowID],
        maxCount: Int?,
        maxConcurrentCaptures: Int
    ) async -> [CGWindowID: NSImage]
    func refreshContentCache() async
    /// Cheaper variant — no-op when the cache is still fresh. Use for
    /// opportunistic warmups (e.g. on NSWorkspace activation) where we don't
    /// want to hammer SCKit on every fast app switch.
    func refreshContentCacheIfStale() async
}

/// Window activation / closing dependency. Concrete WindowActivator conforms;
/// tests verify that selection and close paths call the right method.
protocol WindowActivating: Sendable {
    func activate(_ item: WindowItem)
    func close(_ item: WindowItem)
    /// Sends NSRunningApplication.terminate(). The whole app quits, not just
    /// the selected window.
    func quit(_ item: WindowItem)
    /// Sends NSRunningApplication.hide(). All of the app's windows go away
    /// without quitting; the app stays running and can be reactivated later.
    func hide(_ item: WindowItem)
}

/// Permission-state dependency. Concrete PermissionService conforms; tests
/// inject arbitrary states to exercise permission-aware branches.
protocol PermissionProviding: Sendable {
    func currentState() -> PermissionState
}
