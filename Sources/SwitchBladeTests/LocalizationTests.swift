@testable import SwitchBladeCore

enum LocalizationTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("Localization/everyKey_hasEnglishString", everyKeyHasEnglish),
        ("Localization/everyKey_hasFinnishString", everyKeyHasFinnish),
        ("Localization/setLanguage_switchesTr", setLanguageSwitches),
        ("Localization/systemFallsBackToEnglish_orMatchesLocale", systemFallback),
        ("Localization/appLanguage_displayName_isStable", displayNameStable),
        ("Localization/tr_withArg_substitutes", trWithArg)
    ]

    @MainActor static func everyKeyHasEnglish() throws {
        LocalizationState.shared.selection = .english
        for key in L10n.Key.allCases {
            let value = L10n.tr(key)
            try expect(!value.isEmpty, "English missing for \(key)")
            try expect(value != key.rawValue, "English fallback to rawValue for \(key)")
        }
    }

    @MainActor static func everyKeyHasFinnish() throws {
        LocalizationState.shared.selection = .finnish
        for key in L10n.Key.allCases {
            let value = L10n.tr(key)
            try expect(!value.isEmpty, "Finnish missing for \(key)")
            try expect(value != key.rawValue, "Finnish fallback to rawValue for \(key)")
        }
    }

    @MainActor static func setLanguageSwitches() throws {
        LocalizationState.shared.selection = .english
        let en = L10n.tr(.alertOpenSettings)
        LocalizationState.shared.selection = .finnish
        let fi = L10n.tr(.alertOpenSettings)
        try expectNotEqual(en, fi)
        try expectEqual(en, "Open Settings")
        try expectEqual(fi, "Avaa asetukset")
    }

    @MainActor static func systemFallback() throws {
        LocalizationState.shared.selection = .system
        let effective = LocalizationState.shared.effectiveLanguage
        // System resolves to either Finnish or English — never the .system sentinel.
        try expect(effective == .finnish || effective == .english,
                   "effectiveLanguage must be a concrete language, got \(effective)")
    }

    @MainActor static func displayNameStable() throws {
        try expectEqual(AppLanguage.system.displayName, "System")
        try expectEqual(AppLanguage.english.displayName, "English")
        try expectEqual(AppLanguage.finnish.displayName, "Suomi")
    }

    @MainActor static func trWithArg() throws {
        LocalizationState.shared.selection = .english
        let result = L10n.tr(.alertPermissionTitle, "Accessibility")
        try expectEqual(result, "SwitchBlade needs permission: Accessibility")
    }
}
