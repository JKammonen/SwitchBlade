import AppKit

struct WindowItem: Identifiable, Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
    let isFrontmostApp: Bool
    let isMinimized: Bool
    let preview: NSImage?
    let icon: NSImage?
    /// Bundle identifier of the owning application, when available. Used to
    /// rebuild the MRU ordering after an app restart (CGWindowIDs aren't
    /// stable across launches but bundle IDs are).
    let bundleIdentifier: String?

    var id: CGWindowID { windowID }

    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    var subtitle: String {
        title.isEmpty ? "App" : appName
    }

    func withPreview(_ preview: NSImage?) -> Self {
        WindowItem(
            windowID: windowID,
            pid: pid,
            appName: appName,
            title: title,
            bounds: bounds,
            isFrontmostApp: isFrontmostApp,
            isMinimized: isMinimized,
            preview: preview,
            icon: icon,
            bundleIdentifier: bundleIdentifier
        )
    }
}