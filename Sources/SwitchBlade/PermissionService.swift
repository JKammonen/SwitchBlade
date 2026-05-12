import ApplicationServices
import Foundation

enum PermissionKind: String, CaseIterable {
    case accessibility
    case screenRecording

    var title: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .screenRecording:
            return "Screen Recording"
        }
    }

    var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

struct PermissionState: Equatable {
    let hasAccessibility: Bool
    let hasScreenRecording: Bool

    var needsAccessibility: Bool { !hasAccessibility }
    var needsScreenRecording: Bool { !hasScreenRecording }
    var isReady: Bool { hasAccessibility && hasScreenRecording }

    var missingPermissions: [PermissionKind] {
        var permissions: [PermissionKind] = []
        if needsAccessibility { permissions.append(.accessibility) }
        if needsScreenRecording { permissions.append(.screenRecording) }
        return permissions
    }

    var primaryMissingPermission: PermissionKind? { missingPermissions.first }

    var message: String? {
        switch (needsAccessibility, needsScreenRecording) {
        case (false, false): return nil
        case (true, false):  return "Enable Accessibility for exact window focus."
        case (false, true):  return "Enable Screen Recording for live window previews."
        default:             return "Enable Accessibility and Screen Recording for the full experience."
        }
    }
}

final class PermissionService: Sendable {
    private let accessibilityPromptKey = "AXTrustedCheckOptionPrompt"

    func currentState() -> PermissionState {
        PermissionState(
            hasAccessibility: AXIsProcessTrusted(),
            hasScreenRecording: CGPreflightScreenCaptureAccess()
        )
    }

    func requestIfNeeded() {
        let state = currentState()

        // Accessibility: AXIsProcessTrustedWithOptions shows the standard system
        // prompt safely — this is the documented, idempotent way to request it.
        if state.needsAccessibility {
            let options = [accessibilityPromptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        // Screen Recording: do NOT call CGRequestScreenCaptureAccess().
        // It triggers an OS dialog on every call when TCC doesn't recognize the
        // binary. Instead we show our own NSAlert that opens System Settings.
    }
}