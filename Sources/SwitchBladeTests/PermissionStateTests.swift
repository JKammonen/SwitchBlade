@testable import SwitchBladeCore

enum PermissionStateTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("PermissionState/allGranted_isReady_noMessage", allGranted),
        ("PermissionState/missingAccessibility_isListed", missingAccessibility),
        ("PermissionState/missingScreenRecording_isListed", missingScreenRecording),
        ("PermissionState/iconsOnly_doesNotRequireScreenRecording", iconsOnlyDoesNotRequireScreenRecording),
        ("PermissionState/bothMissing_listsBoth", bothMissing),
        ("PermissionState/recoverySurface_tracksRelevantMissingPermissions", recoverySurfaceTracksRelevantMissingPermissions),
        ("PermissionState/permissionKind_hasURL_andTitle_forEveryCase", everyKindHasURL)
    ]

    static func allGranted() throws {
        LocalizationState.selection = .english
        let state = PermissionState(hasAccessibility: true, hasScreenRecording: true)
        try expect(state.isReady)
        try expect(state.hasAllCapabilities)
        try expect(state.missingPermissions.isEmpty)
        try expectNil(state.primaryMissingPermission)
        try expectNil(state.message)
    }

    static func missingAccessibility() throws {
        LocalizationState.selection = .english
        let state = PermissionState(hasAccessibility: false, hasScreenRecording: true)
        try expect(!state.isReady)
        try expectEqual(state.missingPermissions, [.accessibility])
        try expectEqual(state.primaryMissingPermission, .accessibility)
        try expect(state.message?.contains("Accessibility") == true)
    }

    static func missingScreenRecording() throws {
        LocalizationState.selection = .english
        let state = PermissionState(hasAccessibility: true, hasScreenRecording: false)
        try expect(state.isReady, "Screen Recording is optional for core switching")
        try expect(!state.hasAllCapabilities)
        try expectEqual(state.missingPermissions, [.screenRecording])
        try expect(state.message(for: .livePreviews)?.contains("Screen Recording") == true)
    }

    static func iconsOnlyDoesNotRequireScreenRecording() throws {
        let state = PermissionState(hasAccessibility: true, hasScreenRecording: false)
        try expectEqual(state.missingPermissions(for: .iconsOnly), [])
        try expectNil(state.primaryMissingPermission(for: .iconsOnly))
        try expectNil(state.message(for: .iconsOnly))
    }

    static func bothMissing() throws {
        LocalizationState.selection = .english
        let state = PermissionState(hasAccessibility: false, hasScreenRecording: false)
        try expect(!state.isReady)
        try expectEqual(state.missingPermissions.count, 2)
        try expectNotNil(state.message)
        // Order matters: accessibility comes first
        try expectEqual(state.missingPermissions.first, .accessibility)
        try expectEqual(state.missingPermissions(for: .iconsOnly), [.accessibility])
    }

    static func recoverySurfaceTracksRelevantMissingPermissions() throws {
        let allGranted = PermissionState(hasAccessibility: true, hasScreenRecording: true)
        try expect(!allGranted.needsVisibleRecovery(for: .livePreviews))

        let missingAccessibility = PermissionState(hasAccessibility: false, hasScreenRecording: true)
        try expect(missingAccessibility.needsVisibleRecovery(for: .iconsOnly))

        let missingScreenRecording = PermissionState(hasAccessibility: true, hasScreenRecording: false)
        try expect(missingScreenRecording.needsVisibleRecovery(for: .livePreviews))
        try expect(!missingScreenRecording.needsVisibleRecovery(for: .iconsOnly))
    }

    static func everyKindHasURL() throws {
        LocalizationState.selection = .english
        for kind in PermissionKind.allCases {
            try expect(!kind.settingsURL.absoluteString.isEmpty, "\(kind) settingsURL")
            try expect(!kind.title.isEmpty, "\(kind) title")
        }
        try expectEqual(PermissionKind.accessibility.title, "Accessibility")
        LocalizationState.selection = .finnish
        try expectEqual(PermissionKind.accessibility.title, "Käyttöapu")
    }
}
