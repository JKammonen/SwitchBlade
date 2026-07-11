@testable import SwitchBladeCore

enum LocalizationTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("Localization/everyKey_hasEnglishString", everyKeyHasEnglish),
        ("Localization/everyKey_hasFinnishString", everyKeyHasFinnish),
        ("Localization/setLanguage_switchesTr", setLanguageSwitches),
        ("Localization/systemFallsBackToEnglish_orMatchesLocale", systemFallback),
        ("Localization/appLanguage_displayName_isStable", displayNameStable),
        ("Localization/tr_withArg_substitutes", trWithArg),
        ("Localization/finnishPermissionNames_areNative", finnishPermissionNamesAreNative),
        ("Localization/hiddenAppSummary_supportsTwoCounts", hiddenAppSummarySupportsTwoCounts)
    ]

    @MainActor static func everyKeyHasEnglish() throws {
        LocalizationState.selection = .english
        for key in L10n.Key.allCases {
            let value = L10n.tr(key)
            try expect(!value.isEmpty, "English missing for \(key)")
            try expect(value != key.rawValue, "English fallback to rawValue for \(key)")
        }
    }

    @MainActor static func everyKeyHasFinnish() throws {
        LocalizationState.selection = .finnish
        for key in L10n.Key.allCases {
            let value = L10n.tr(key)
            try expect(!value.isEmpty, "Finnish missing for \(key)")
            try expect(value != key.rawValue, "Finnish fallback to rawValue for \(key)")
        }
    }

    @MainActor static func setLanguageSwitches() throws {
        LocalizationState.selection = .english
        let en = L10n.tr(.alertOpenSettings)
        LocalizationState.selection = .finnish
        let fi = L10n.tr(.alertOpenSettings)
        try expectNotEqual(en, fi)
        try expectEqual(en, "Open Settings")
        try expectEqual(fi, "Avaa asetukset")
    }

    @MainActor static func systemFallback() throws {
        LocalizationState.selection = .system
        let effective = LocalizationState.effectiveLanguage
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
        LocalizationState.selection = .english
        let result = L10n.tr(.alertPermissionTitle, "Accessibility")
        try expectEqual(result, "SwitchBlade needs permission: Accessibility")
    }

    @MainActor static func finnishPermissionNamesAreNative() throws {
        try expectEqual(L10n.tr(.permissionNameAccessibility, language: .finnish), "Käyttöapu")
        try expectEqual(L10n.tr(.permissionNameScreenRecording, language: .finnish), "Näytön tallennus")
        try expectEqual(L10n.tr(.permissionActionOpenSettings, language: .finnish), "Avaa Järjestelmäasetukset")
        try expectEqual(L10n.tr(.permissionActionOpenSettingsShort, language: .finnish), "Avaa asetukset")
        try expectEqual(L10n.tr(.fieldColorStrength, language: .finnish), "Värin voimakkuus")
        try expectEqual(L10n.tr(.fieldOpacity, language: .finnish), "Peittävyys")
        try expect(!L10n.tr(.permissionMessageBoth, language: .finnish).contains("Accessibility"))
        try expect(!L10n.tr(.permissionMessageBoth, language: .finnish).contains("Screen Recording"))
    }

    @MainActor static func hiddenAppSummarySupportsTwoCounts() throws {
        let format = L10n.tr(.hiddenAppsParsedSummary, language: .english)
        try expectEqual(String(format: format, 2, 3), "Parsed rules: 2 substring, 3 exact")
    }
}
