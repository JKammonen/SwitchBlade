import ApplicationServices
import Foundation

enum PermissionKind: String, CaseIterable {
    case accessibility
    case screenRecording

    var title: String {
        switch self {
        case .accessibility:
            return L10n.tr(.permissionNameAccessibility)
        case .screenRecording:
            return L10n.tr(.permissionNameScreenRecording)
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
    /// Accessibility is required for the global switcher. Screen Recording is
    /// an optional preview capability and is irrelevant in icons-only mode.
    var isReady: Bool { hasAccessibility }
    var hasAllCapabilities: Bool { hasAccessibility && hasScreenRecording }

    var missingPermissions: [PermissionKind] {
        var permissions: [PermissionKind] = []
        if needsAccessibility { permissions.append(.accessibility) }
        if needsScreenRecording { permissions.append(.screenRecording) }
        return permissions
    }

    var primaryMissingPermission: PermissionKind? { missingPermissions.first }

    func missingPermissions(for previewMode: SBPreviewMode) -> [PermissionKind] {
        var permissions: [PermissionKind] = []
        if needsAccessibility { permissions.append(.accessibility) }
        if previewMode != .iconsOnly, needsScreenRecording {
            permissions.append(.screenRecording)
        }
        return permissions
    }

    func primaryMissingPermission(for previewMode: SBPreviewMode) -> PermissionKind? {
        missingPermissions(for: previewMode).first
    }

    func needsVisibleRecovery(for previewMode: SBPreviewMode) -> Bool {
        !missingPermissions(for: previewMode).isEmpty
    }

    var message: String? {
        switch (needsAccessibility, needsScreenRecording) {
        case (false, false): return nil
        case (true, false):  return L10n.tr(.permissionMessageAccessibility)
        case (false, true):  return L10n.tr(.permissionMessageScreenRecording)
        default:             return L10n.tr(.permissionMessageBoth)
        }
    }

    func message(for previewMode: SBPreviewMode) -> String? {
        let relevant = missingPermissions(for: previewMode)
        switch (relevant.contains(.accessibility), relevant.contains(.screenRecording)) {
        case (false, false): return nil
        case (true, false):  return L10n.tr(.permissionMessageAccessibility)
        case (false, true):  return L10n.tr(.permissionMessageScreenRecording)
        case (true, true):   return L10n.tr(.permissionMessageBoth)
        }
    }
}

final class PermissionService: PermissionProviding, Sendable {
    private let accessibilityPromptKey = "AXTrustedCheckOptionPrompt"

    func currentState() -> PermissionState {
        PermissionState(
            hasAccessibility: AXIsProcessTrusted(),
            hasScreenRecording: CGPreflightScreenCaptureAccess()
        )
    }

    /// Called only from an explicit user action in a visible recovery surface.
    /// AppDelegate follows this with the relevant System Settings deep link for
    /// both permissions, because macOS may suppress a previously denied prompt.
    func request(_ permission: PermissionKind) {
        if permission == .accessibility, currentState().needsAccessibility {
            let options = [accessibilityPromptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }
}
