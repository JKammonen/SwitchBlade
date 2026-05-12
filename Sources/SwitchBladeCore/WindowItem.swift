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
            icon: icon
        )
    }
}