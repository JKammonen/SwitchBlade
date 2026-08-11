import AppKit

/// Immutable, image-free payload safe to send to an off-main AX worker.
/// NSImage-backed WindowItem stays on MainActor/UI paths.
struct WindowActionTarget: Identifiable, Equatable, Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
    let isFrontmostApp: Bool
    let isMinimized: Bool
    let bundleIdentifier: String?
    /// Process that owns the AX/WindowServer window when it differs from the
    /// regular application process (for example a nested renderer process).
    let windowOwnerPID: pid_t?

    var id: CGWindowID { windowID }
    var windowProcessIdentifier: pid_t { windowOwnerPID ?? pid }
}

struct WindowItem: Identifiable, Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
    let isFrontmostApp: Bool
    let isMinimized: Bool
    let canCapturePreview: Bool
    let isTitleRedacted: Bool
    let preview: NSImage?
    let icon: NSImage?
    /// Bundle identifier of the owning application, when available. Used to
    /// rebuild the MRU ordering after an app restart (CGWindowIDs aren't
    /// stable across launches but bundle IDs are).
    let bundleIdentifier: String?
    /// Process that owns the concrete window. `pid` remains the regular host
    /// application so app-level ordering, activation, hide, and quit keep their
    /// existing semantics.
    let windowOwnerPID: pid_t?

    var id: CGWindowID { windowID }
    var windowProcessIdentifier: pid_t { windowOwnerPID ?? pid }

    var displayTitle: String {
        isTitleRedacted || title.isEmpty ? appName : title
    }

    var subtitle: String {
        isTitleRedacted || title.isEmpty ? "App" : appName
    }

    var actionTarget: WindowActionTarget {
        WindowActionTarget(
            windowID: windowID,
            pid: pid,
            appName: appName,
            title: title,
            bounds: bounds,
            isFrontmostApp: isFrontmostApp,
            isMinimized: isMinimized,
            bundleIdentifier: bundleIdentifier,
            windowOwnerPID: windowOwnerPID
        )
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
            canCapturePreview: canCapturePreview,
            isTitleRedacted: isTitleRedacted,
            preview: preview,
            icon: icon,
            bundleIdentifier: bundleIdentifier,
            windowOwnerPID: windowOwnerPID
        )
    }

    func withFrontmostState(_ isFrontmostApp: Bool) -> Self {
        WindowItem(
            windowID: windowID,
            pid: pid,
            appName: appName,
            title: title,
            bounds: bounds,
            isFrontmostApp: isFrontmostApp,
            isMinimized: isMinimized,
            canCapturePreview: canCapturePreview,
            isTitleRedacted: isTitleRedacted,
            preview: preview,
            icon: icon,
            bundleIdentifier: bundleIdentifier,
            windowOwnerPID: windowOwnerPID
        )
    }
}
