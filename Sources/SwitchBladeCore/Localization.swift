import Foundation

/// User-selectable interface language.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english
    case finnish

    public var displayName: String {
        // Always shown in the picker — keep static, not localized (so users in
        // a language they don't know can still find their language).
        switch self {
        case .system:  return "System"
        case .english: return "English"
        case .finnish: return "Suomi"
        }
    }
}

/// Thread-safe, actor-agnostic storage of the user's "restrict to current
/// Space" toggle. WindowCatalog (Sendable, non-MainActor) reads this in its
/// hot path; SwitchBladeSettings mirrors the value on every change.
public enum WindowFilterState {
    private static let storage = LockedValue<Bool>(true)
    public static var restrictToCurrentSpace: Bool {
        get { storage.value }
        set { storage.value = newValue }
    }
}

/// Thread-safe, actor-agnostic storage of the current effective language so
/// localization can be queried from any isolation context (including struct
/// computed properties like `PermissionState.message`).
///
/// Mirrored from `SwitchBladeSettings.language` on every change.
public enum LocalizationState {
    private static let storage = LockedValue<AppLanguage>(.system)

    public static var selection: AppLanguage {
        get { storage.value }
        set { storage.value = newValue }
    }

    /// Resolves `.system` to a concrete language based on the OS preferred
    /// languages. Falls back to English when the user's preference is neither
    /// Finnish nor English.
    public static var effectiveLanguage: AppLanguage {
        switch selection {
        case .english: return .english
        case .finnish: return .finnish
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("fi") ? .finnish : .english
        }
    }
}

/// Localization table. Add a key here, then provide both English and Finnish
/// strings; `L10n.tr(.key)` returns the right one based on the current setting.
public enum L10n {
    public enum Key: String, CaseIterable {
        // SettingsView — sections
        case settingsLanguage
        case settingsBehavior
        case settingsHotkey
        case settingsBackground
        case settingsBadgeBar
        case settingsSelection
        case settingsPreviewSize

        // Behavior
        case fieldRestrictToCurrentSpace

        // SettingsView — fields
        case fieldLanguage
        case fieldModifier
        case fieldTriggerKey
        case fieldActiveCombo
        case fieldColor
        case fieldOpacity
        case fieldPosition
        case fieldAppIconColor
        case fieldIconSize
        case fieldTextSize
        case fieldVerticalPadding
        case fieldAnimation
        case fieldHighlightColor
        case fieldStrength
        case fieldMinWidth

        // Permission messages
        case permissionMessageAccessibility
        case permissionMessageScreenRecording
        case permissionMessageBoth

        // Permission alert (AppDelegate)
        case alertPermissionTitle           // formatted with permission title
        case alertPermissionBody            // formatted with missing list
        case alertOpenSettings
        case alertLater

        // Permission kind titles (kept in English because they mirror macOS
        // System Settings labels — translating would actively confuse).
        // Not part of this table; rendered via PermissionKind.title verbatim.

        // Modifiers
        case modifierCommand
        case modifierOption
        case modifierControl

        // Trigger keys
        case keyTab
        case keyBacktick
        case keySpace

        // Selection effects
        case selectionPump
        case selectionBreathe
        case selectionBounce
        case selectionFloat
        case selectionWobble

        // Badge positions
        case badgeBottom
        case badgeTop
    }

    public static func tr(_ key: Key) -> String {
        let lang = LocalizationState.effectiveLanguage
        return table(for: lang)[key] ?? englishTable[key] ?? key.rawValue
    }

    /// Format-string variant for messages with one substitution.
    public static func tr(_ key: Key, _ arg: CVarArg) -> String {
        String(format: tr(key), arg)
    }

    // MARK: - Tables

    private static func table(for lang: AppLanguage) -> [Key: String] {
        switch lang {
        case .english, .system: return englishTable
        case .finnish:          return finnishTable
        }
    }

    // Dictionaries are immutable after init but Swift 6 flags `static let` on a
    // generic container as potential global mutable state. The values never
    // change at runtime, so `nonisolated(unsafe)` is correct here.
    nonisolated(unsafe) private static let englishTable: [Key: String] = [
        .settingsLanguage:                "Language",
        .settingsBehavior:                "Behavior",
        .fieldRestrictToCurrentSpace:     "Only current Space",
        .settingsHotkey:                  "Hotkey",
        .settingsBackground:              "Background",
        .settingsBadgeBar:                "Badge bar",
        .settingsSelection:               "Selection",
        .settingsPreviewSize:             "Preview size",

        .fieldLanguage:                   "Language",
        .fieldModifier:                   "Modifier",
        .fieldTriggerKey:                 "Trigger key",
        .fieldActiveCombo:                "Active: %@",
        .fieldColor:                      "Color",
        .fieldOpacity:                    "Opacity",
        .fieldPosition:                   "Position",
        .fieldAppIconColor:               "App icon color",
        .fieldIconSize:                   "Icon size",
        .fieldTextSize:                   "Text size",
        .fieldVerticalPadding:            "Vert. padding",
        .fieldAnimation:                  "Animation",
        .fieldHighlightColor:             "Highlight color",
        .fieldStrength:                   "Strength",
        .fieldMinWidth:                   "Min width",

        .permissionMessageAccessibility:  "Enable Accessibility for exact window focus.",
        .permissionMessageScreenRecording:"Enable Screen Recording for live window previews.",
        .permissionMessageBoth:           "Enable Accessibility and Screen Recording for the full experience.",

        .alertPermissionTitle:            "SwitchBlade needs permission: %@",
        .alertPermissionBody:             "SwitchBlade requires permission to operate. Missing permissions: %@. Open the relevant System Settings page and enable SwitchBlade.",
        .alertOpenSettings:               "Open Settings",
        .alertLater:                      "Later",

        .modifierCommand:                 "⌘ Command",
        .modifierOption:                  "⌥ Option",
        .modifierControl:                 "⌃ Control",

        .keyTab:                          "Tab",
        .keyBacktick:                     "Backtick (`)",
        .keySpace:                        "Space",

        .selectionPump:                   "Pump",
        .selectionBreathe:                "Breathe",
        .selectionBounce:                 "Bounce",
        .selectionFloat:                  "Float",
        .selectionWobble:                 "Wobble",

        .badgeBottom:                     "Bottom",
        .badgeTop:                        "Top"
    ]

    nonisolated(unsafe) private static let finnishTable: [Key: String] = [
        .settingsLanguage:                "Kieli",
        .settingsBehavior:                "Toiminta",
        .fieldRestrictToCurrentSpace:     "Vain nykyinen Space",
        .settingsHotkey:                  "Pikanäppäin",
        .settingsBackground:              "Tausta",
        .settingsBadgeBar:                "Otsikkopalkki",
        .settingsSelection:               "Valinta",
        .settingsPreviewSize:             "Esikatselun koko",

        .fieldLanguage:                   "Kieli",
        .fieldModifier:                   "Muunnosnäppäin",
        .fieldTriggerKey:                 "Laukaisin",
        .fieldActiveCombo:                "Aktiivinen: %@",
        .fieldColor:                      "Väri",
        .fieldOpacity:                    "Läpinäkyvyys",
        .fieldPosition:                   "Sijainti",
        .fieldAppIconColor:               "Sovelluksen kuvakkeen väri",
        .fieldIconSize:                   "Kuvakkeen koko",
        .fieldTextSize:                   "Tekstin koko",
        .fieldVerticalPadding:            "Pystysuora täyte",
        .fieldAnimation:                  "Animaatio",
        .fieldHighlightColor:             "Korostusväri",
        .fieldStrength:                   "Voimakkuus",
        .fieldMinWidth:                   "Vähimmäisleveys",

        .permissionMessageAccessibility:  "Salli Accessibility tarkkaa ikkunafokusta varten.",
        .permissionMessageScreenRecording:"Salli Screen Recording elävien esikatselujen näyttämiseksi.",
        .permissionMessageBoth:           "Salli Accessibility ja Screen Recording täyden toiminnallisuuden saamiseksi.",

        .alertPermissionTitle:            "SwitchBlade tarvitsee luvan: %@",
        .alertPermissionBody:             "SwitchBlade tarvitsee luvan toimiakseen. Puuttuvat luvat: %@. Avaa oikea System Settings -sivu ja laita SwitchBlade päälle.",
        .alertOpenSettings:               "Avaa asetukset",
        .alertLater:                      "Myöhemmin",

        .modifierCommand:                 "⌘ Command",
        .modifierOption:                  "⌥ Option",
        .modifierControl:                 "⌃ Control",

        .keyTab:                          "Tab",
        .keyBacktick:                     "Aksenttipiste (`)",
        .keySpace:                        "Välilyönti",

        .selectionPump:                   "Pumppu",
        .selectionBreathe:                "Hengitys",
        .selectionBounce:                 "Pomppu",
        .selectionFloat:                  "Leijunta",
        .selectionWobble:                 "Heilunta",

        .badgeBottom:                     "Alhaalla",
        .badgeTop:                        "Ylhäällä"
    ]
}
