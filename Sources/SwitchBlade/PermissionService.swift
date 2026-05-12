import ApplicationServices
import Foundation

enum PermissionKind: String, CaseIterable {
    case inputMonitoring
    case accessibility
    case screenRecording

    var title: String {
        switch self {
        case .inputMonitoring:
            return "Input Monitoring"
        case .accessibility:
            return "Accessibility"
        case .screenRecording:
            return "Screen Recording"
        }
    }

    var settingsURL: URL {
        switch self {
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
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
    let hasInputMonitoring: Bool

    var needsAccessibility: Bool { !hasAccessibility }
    var needsScreenRecording: Bool { !hasScreenRecording }
    var needsInputMonitoring: Bool { !hasInputMonitoring }
    var isReady: Bool {
        hasAccessibility && hasScreenRecording && hasInputMonitoring
    }

    var missingPermissions: [PermissionKind] {
        var permissions: [PermissionKind] = []
        if needsInputMonitoring {
            permissions.append(.inputMonitoring)
        }
        if needsAccessibility {
            permissions.append(.accessibility)
        }
        if needsScreenRecording {
            permissions.append(.screenRecording)
        }
        return permissions
    }

    var primaryMissingPermission: PermissionKind? {
        missingPermissions.first
    }

    var message: String? {
        switch (needsAccessibility, needsInputMonitoring, needsScreenRecording) {
        case (false, false, false):
            return nil
        case (true, false, false):
            return "Enable Accessibility for exact window focus."
        case (false, true, false):
            return "Enable Input Monitoring for global Command+Tab capture."
        case (false, false, true):
            return "Enable Screen Recording for live window previews."
        default:
            return "Enable Accessibility, Input Monitoring, and Screen Recording for the full experience."
        }
    }
}

final class PermissionService: Sendable {
    private let accessibilityPromptKey = "AXTrustedCheckOptionPrompt"

    func currentState() -> PermissionState {
        PermissionState(
            hasAccessibility: AXIsProcessTrusted(),
            hasScreenRecording: CGPreflightScreenCaptureAccess(),
            hasInputMonitoring: CGPreflightListenEventAccess()
        )
    }

    func requestIfNeeded() {
        let state = currentState()

        // Accessibility: AXIsProcessTrustedWithOptions is idempotent and shows
        // the standard system prompt safely — this is the documented way.
        if state.needsAccessibility {
            let options = [accessibilityPromptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        // Screen Recording + Input Monitoring: do NOT call CGRequest* APIs.
        // They trigger an OS dialog on every call when TCC doesn't recognize
        // the binary (e.g. after a rebuild/recodesign). Instead we show our
        // own NSAlert that opens System Settings — the user grants it once,
        // CGPreflight* then returns true, and we stop asking entirely.
    }
}