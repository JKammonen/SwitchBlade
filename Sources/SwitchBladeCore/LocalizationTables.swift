import Foundation

// Dictionaries are immutable after init but Swift 6 flags `static let` on a
// generic container as potential global mutable state. The values never
// change at runtime, so `nonisolated(unsafe)` is correct here.
enum L10nTables {
    nonisolated(unsafe) static let english: [L10n.Key: String] = [
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
        .fieldDoubleModifierSwitch:       "Quick previous-app shortcuts",
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
        .windowStateMinimized:            "Minimized",

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
        .badgeTop:                        "Top",

        .menuSettings:                    "Settings…",
        .menuAbout:                       "About SwitchBlade",
        .menuQuit:                        "Quit SwitchBlade",
        .menuSettingsWindowTitle:         "SwitchBlade Settings",
        .tooltipSettings:                 "Settings",
        .aboutBuiltAt:                    "Built"
    ]

    nonisolated(unsafe) static let finnish: [L10n.Key: String] = [
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
        .fieldDoubleModifierSwitch:       "Nopeat edellinen appi -oikotiet",
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
        .windowStateMinimized:            "Minimoitu",

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
        .badgeTop:                        "Ylhäällä",

        .menuSettings:                    "Asetukset…",
        .menuAbout:                       "Tietoja SwitchBladesta",
        .menuQuit:                        "Lopeta SwitchBlade",
        .menuSettingsWindowTitle:         "SwitchBlade-asetukset",
        .tooltipSettings:                 "Asetukset",
        .aboutBuiltAt:                    "Buildattu"
    ]
}
