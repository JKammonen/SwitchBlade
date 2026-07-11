import AppKit
import CoreGraphics

final class CooperativeCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Window-listing dependency for SwitcherStore. Concrete WindowCatalog conforms;
/// tests inject a mock to drive snapshot contents without touching real CGWindow
/// or ScreenCaptureKit APIs.
protocol WindowSnapshotProviding: Sendable {
    func snapshotVisibleOnly() -> [WindowItem]
    func snapshotMinimized(cancellation: CooperativeCancellationToken) async -> [WindowItem]
    /// Resolves the AX-focused window of `pid` against a fresh visible
    /// snapshot. nil when AX fails or the match is ambiguous.
    func focusedWindowItem(pid: pid_t) -> WindowItem?
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
    /// Drops cached ScreenCaptureKit content after lifecycle events that can
    /// make SCWindow references stale (sleep/wake, display reconfiguration).
    func invalidateContentCache(reason: String) async
}

/// Window activation / closing dependency. Concrete WindowActivator conforms;
/// tests verify that selection and close paths call the right method.
protocol WindowActivating: Sendable {
    func activate(_ item: WindowActionTarget) -> Bool
    func activateApplication(pid: pid_t) -> Bool
    func snap(_ item: WindowActionTarget, to edge: WindowSnapEdge) -> Bool
    func close(_ item: WindowActionTarget) -> Bool
    /// Sends NSRunningApplication.terminate(). The whole app quits, not just
    /// the selected window.
    func quit(_ item: WindowActionTarget) -> Bool
    /// Sends NSRunningApplication.hide(). All of the app's windows go away
    /// without quitting; the app stays running and can be reactivated later.
    func hide(_ item: WindowActionTarget) -> Bool
}

/// Permission-state dependency. Concrete PermissionService conforms; tests
/// inject arbitrary states to exercise permission-aware branches.
protocol PermissionProviding: Sendable {
    func currentState() -> PermissionState
}
