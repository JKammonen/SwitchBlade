@testable import SwitchBladeCore

enum PermissionStateTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("PermissionState/allGranted_isReady_noMessage", allGranted),
        ("PermissionState/missingAccessibility_isListed", missingAccessibility),
        ("PermissionState/missingScreenRecording_isListed", missingScreenRecording),
        ("PermissionState/bothMissing_listsBoth", bothMissing),
        ("PermissionState/permissionKind_hasURL_andTitle_forEveryCase", everyKindHasURL)
    ]

    static func allGranted() throws {
        let state = PermissionState(hasAccessibility: true, hasScreenRecording: true)
        try expect(state.isReady)
        try expect(state.missingPermissions.isEmpty)
        try expectNil(state.primaryMissingPermission)
        try expectNil(state.message)
    }

    static func missingAccessibility() throws {
        let state = PermissionState(hasAccessibility: false, hasScreenRecording: true)
        try expect(!state.isReady)
        try expectEqual(state.missingPermissions, [.accessibility])
        try expectEqual(state.primaryMissingPermission, .accessibility)
        try expect(state.message?.contains("Accessibility") == true)
    }

    static func missingScreenRecording() throws {
        let state = PermissionState(hasAccessibility: true, hasScreenRecording: false)
        try expect(!state.isReady)
        try expectEqual(state.missingPermissions, [.screenRecording])
        try expect(state.message?.contains("Screen Recording") == true)
    }

    static func bothMissing() throws {
        let state = PermissionState(hasAccessibility: false, hasScreenRecording: false)
        try expect(!state.isReady)
        try expectEqual(state.missingPermissions.count, 2)
        try expectNotNil(state.message)
        // Order matters: accessibility comes first
        try expectEqual(state.missingPermissions.first, .accessibility)
    }

    static func everyKindHasURL() throws {
        for kind in PermissionKind.allCases {
            try expect(!kind.settingsURL.absoluteString.isEmpty, "\(kind) settingsURL")
            try expect(!kind.title.isEmpty, "\(kind) title")
        }
    }
}
