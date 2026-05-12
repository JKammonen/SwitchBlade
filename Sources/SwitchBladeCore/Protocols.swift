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
}

/// Window activation / closing dependency. Concrete WindowActivator conforms;
/// tests verify that selection and close paths call the right method.
protocol WindowActivating: Sendable {
    func activate(_ item: WindowItem)
    func close(_ item: WindowItem)
}

/// Permission-state dependency. Concrete PermissionService conforms; tests
/// inject arbitrary states to exercise permission-aware branches.
protocol PermissionProviding: Sendable {
    func currentState() -> PermissionState
}
