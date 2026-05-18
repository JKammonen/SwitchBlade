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

public enum SBWindowScope: String, CaseIterable, Identifiable, Sendable {
    case currentSpace = "currentSpace"
    case allSpaces = "allSpaces"
    case currentApp = "currentApp"

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .currentSpace: return L10n.tr(.windowScopeCurrentSpace)
        case .allSpaces:    return L10n.tr(.windowScopeAllSpaces)
        case .currentApp:   return L10n.tr(.windowScopeCurrentApp)
        }
    }
}

public enum SBPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case livePreviews = "livePreviews"
    case blurredPreviews = "blurredPreviews"
    case iconsOnly = "iconsOnly"

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .livePreviews:    return L10n.tr(.previewModeLive)
        case .blurredPreviews: return L10n.tr(.previewModeBlurred)
        case .iconsOnly:       return L10n.tr(.previewModeIconsOnly)
        }
    }
}

public enum SBSortOrder: String, CaseIterable, Identifiable, Sendable {
    case recentlyUsed = "recentlyUsed"
    case appGrouped = "appGrouped"
    case alphabetical = "alphabetical"

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyUsed:  return L10n.tr(.sortRecentlyUsed)
        case .appGrouped:   return L10n.tr(.sortAppGrouped)
        case .alphabetical: return L10n.tr(.sortAlphabetical)
        }
    }
}

public enum SBPerformanceLogging: String, CaseIterable, Identifiable, Sendable {
    case off = "off"
    case basic = "basic"
    case debug = "debug"

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .off:   return L10n.tr(.loggingOff)
        case .basic: return L10n.tr(.loggingBasic)
        case .debug: return L10n.tr(.loggingDebug)
        }
    }
}

public enum WindowSnapEdge: String, CaseIterable, Identifiable, Sendable {
    case left
    case right
    case top
    case bottom

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .left:   return L10n.tr(.actionSnapLeft)
        case .right:  return L10n.tr(.actionSnapRight)
        case .top:    return L10n.tr(.actionSnapTop)
        case .bottom: return L10n.tr(.actionSnapBottom)
        }
    }

    var symbolName: String {
        switch self {
        case .left:   return "arrow.left"
        case .right:  return "arrow.right"
        case .top:    return "arrow.up"
        case .bottom: return "arrow.down"
        }
    }
}

/// Thread-safe, actor-agnostic storage of the user's window scope. WindowCatalog
/// (Sendable, non-MainActor) reads this in its hot path; SwitchBladeSettings
/// mirrors the value on every change.
public enum WindowFilterState {
    private static let storage = LockedValue<SBWindowScope>(.currentSpace)

    public static var scope: SBWindowScope {
        get { storage.value }
        set { storage.value = newValue }
    }

    public static var restrictToCurrentSpace: Bool {
        get { storage.value == .currentSpace }
        set { storage.value = newValue ? .currentSpace : .allSpaces }
    }
}

/// A hidden-app filter rule. Comes in two flavors:
///   - `.contains("code")` matches both "Code" and "Xcode". Default for bare
///     tokens, kept for back-compat with users who already typed "Slack" etc.
///   - `.exact("code")` matches only when the app name or bundle id is exactly
///     "code". Opt-in via leading `=` in the settings field, e.g. `=Code`.
/// Stored lowercased — match comparison lowercases the candidate strings.
public enum HiddenAppToken: Hashable, Sendable {
    case contains(String)
    case exact(String)

    public func matches(appName: String, bundleIdentifier: String?) -> Bool {
        let app = appName.lowercased()
        let bundle = (bundleIdentifier ?? "").lowercased()
        switch self {
        case .contains(let value):
            return app.contains(value) || bundle.contains(value)
        case .exact(let value):
            return app == value || bundle == value
        }
    }
}

public enum HiddenAppFilterState {
    private static let storage = LockedValue<Set<HiddenAppToken>>([])

    public static var normalizedTokens: Set<HiddenAppToken> {
        get { storage.value }
        set { storage.value = newValue }
    }
}

public enum PerformanceLoggingState {
    private static let storage = LockedValue<SBPerformanceLogging>(.basic)

    public static var mode: SBPerformanceLogging {
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
        case settingsPrivacy
        case settingsAdvanced
        case settingsBackground
        case settingsBadgeBar
        case settingsSelection
        case settingsPreviewSize

        // Behavior
        case fieldLaunchAtLogin
        case fieldShowMenuBarIcon
        case fieldWindowScope
        case fieldPreviewMode
        case fieldSortOrder
        case fieldHiddenApps
        case fieldReducedMotion
        case fieldPerformanceLogging
        case fieldResetAppearance

        // SettingsView — fields
        case fieldLanguage
        case fieldModifier
        case fieldTriggerKey
        case fieldActiveCombo
        case fieldDoubleModifierSwitch
        case fieldDoubleModifier
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
        case actionSnapWindow
        case actionSnapLeft
        case actionSnapRight
        case actionSnapTop
        case actionSnapBottom

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

        // Window scopes
        case windowScopeCurrentSpace
        case windowScopeAllSpaces
        case windowScopeCurrentApp

        // Preview modes
        case previewModeLive
        case previewModeBlurred
        case previewModeIconsOnly

        // Sort modes
        case sortRecentlyUsed
        case sortAppGrouped
        case sortAlphabetical

        // Performance logging
        case loggingOff
        case loggingBasic
        case loggingDebug

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
        .settingsPrivacy:                 "Privacy",
        .settingsAdvanced:                "Advanced",
        .fieldLaunchAtLogin:              "Launch at login",
        .fieldShowMenuBarIcon:            "Menu bar icon",
        .fieldWindowScope:                "Window scope",
        .fieldPreviewMode:                "Preview mode",
        .fieldSortOrder:                  "Sort order",
        .fieldHiddenApps:                 "Hidden apps",
        .fieldReducedMotion:              "Reduced motion",
        .fieldPerformanceLogging:         "Performance logging",
        .fieldResetAppearance:            "Reset appearance",
        .settingsHotkey:                  "Hotkey",
        .settingsBackground:              "Background",
        .settingsBadgeBar:                "Badge bar",
        .settingsSelection:               "Selection",
        .settingsPreviewSize:             "Preview size",

        .fieldLanguage:                   "Language",
        .fieldModifier:                   "Modifier",
        .fieldTriggerKey:                 "Trigger key",
        .fieldActiveCombo:                "Active: %@",
        .fieldDoubleModifierSwitch:       "Double modifier switches back",
        .fieldDoubleModifier:             "Double modifier",
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
        .actionSnapWindow:                "Snap window",
        .actionSnapLeft:                  "Left",
        .actionSnapRight:                 "Right",
        .actionSnapTop:                   "Up",
        .actionSnapBottom:                "Down",

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

        .windowScopeCurrentSpace:         "Current Space",
        .windowScopeAllSpaces:            "All Spaces",
        .windowScopeCurrentApp:           "Current app",

        .previewModeLive:                 "Live previews",
        .previewModeBlurred:              "Blur previews",
        .previewModeIconsOnly:            "Icons only",

        .sortRecentlyUsed:                "Recently used",
        .sortAppGrouped:                  "Group by app",
        .sortAlphabetical:                "Alphabetical",

        .loggingOff:                      "Off",
        .loggingBasic:                    "Basic",
        .loggingDebug:                    "Debug",

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
        .settingsPrivacy:                 "Yksityisyys",
        .settingsAdvanced:                "Lisäasetukset",
        .fieldLaunchAtLogin:              "Avaa kirjautuessa",
        .fieldShowMenuBarIcon:            "Valikkorivin kuvake",
        .fieldWindowScope:                "Ikkunoiden rajaus",
        .fieldPreviewMode:                "Esikatselutila",
        .fieldSortOrder:                  "Järjestys",
        .fieldHiddenApps:                 "Piilotetut sovellukset",
        .fieldReducedMotion:              "Vähennä liikettä",
        .fieldPerformanceLogging:         "Suorituskykylokit",
        .fieldResetAppearance:            "Palauta ulkoasu",
        .settingsHotkey:                  "Pikanäppäin",
        .settingsBackground:              "Tausta",
        .settingsBadgeBar:                "Otsikkopalkki",
        .settingsSelection:               "Valinta",
        .settingsPreviewSize:             "Esikatselun koko",

        .fieldLanguage:                   "Kieli",
        .fieldModifier:                   "Muunnosnäppäin",
        .fieldTriggerKey:                 "Laukaisin",
        .fieldActiveCombo:                "Aktiivinen: %@",
        .fieldDoubleModifierSwitch:       "Modifier-tuplapainallus takaisin",
        .fieldDoubleModifier:             "Tuplapainalluksen näppäin",
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
        .actionSnapWindow:                "Puolita ikkuna",
        .actionSnapLeft:                  "Vasen",
        .actionSnapRight:                 "Oikea",
        .actionSnapTop:                   "Ylös",
        .actionSnapBottom:                "Alas",

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

        .windowScopeCurrentSpace:         "Nykyinen Space",
        .windowScopeAllSpaces:            "Kaikki Spacet",
        .windowScopeCurrentApp:           "Nykyinen sovellus",

        .previewModeLive:                 "Elävät esikatselut",
        .previewModeBlurred:              "Sumenna esikatselut",
        .previewModeIconsOnly:            "Vain ikonit",

        .sortRecentlyUsed:                "Viimeksi käytetyt",
        .sortAppGrouped:                  "Ryhmittele sovelluksittain",
        .sortAlphabetical:                "Aakkosjärjestys",

        .loggingOff:                      "Pois",
        .loggingBasic:                    "Perus",
        .loggingDebug:                    "Debug",

        .selectionPump:                   "Pumppu",
        .selectionBreathe:                "Hengitys",
        .selectionBounce:                 "Pomppu",
        .selectionFloat:                  "Leijunta",
        .selectionWobble:                 "Heilunta",

        .badgeBottom:                     "Alhaalla",
        .badgeTop:                        "Ylhäällä"
    ]
}
