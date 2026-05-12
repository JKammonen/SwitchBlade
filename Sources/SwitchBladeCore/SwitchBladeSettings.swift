import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import SwiftUI

enum SwitcherLayout {
    /// Shared by `SwitcherView.WindowTile.aspectRatio(...)` and `SwitcherPanelController.sizeAndCenter`.
    /// Changing one without the other clips tiles or leaves gaps.
    static let tileAspectRatio: CGFloat = 1.65
}

enum SBBadgePosition: String, CaseIterable, Identifiable {
    case bottom = "bottom"
    case top    = "top"

    var id: String { rawValue }
    var title: String { L10n.tr(self == .bottom ? .badgeBottom : .badgeTop) }
}

enum SBSelectionEffect: String, CaseIterable, Identifiable {
    case pump = "pump"
    case breathe = "breathe"
    case bounce = "bounce"
    case float = "float"
    case wobble = "wobble"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pump:    return L10n.tr(.selectionPump)
        case .breathe: return L10n.tr(.selectionBreathe)
        case .bounce:  return L10n.tr(.selectionBounce)
        case .float:   return L10n.tr(.selectionFloat)
        case .wobble:  return L10n.tr(.selectionWobble)
        }
    }
}

// MARK: - Enums

enum SBModifier: String, CaseIterable, Identifiable {
    case command = "command"
    case option  = "option"
    case control = "control"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .command: return L10n.tr(.modifierCommand)
        case .option:  return L10n.tr(.modifierOption)
        case .control: return L10n.tr(.modifierControl)
        }
    }

    var cgFlag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .option:  return .maskAlternate
        case .control: return .maskControl
        }
    }

    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .option:  return .option
        case .control: return .control
        }
    }
}

enum SBTriggerKey: String, CaseIterable, Identifiable {
    case tab      = "tab"
    case backtick = "backtick"
    case space    = "space"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tab:      return L10n.tr(.keyTab)
        case .backtick: return L10n.tr(.keyBacktick)
        case .space:    return L10n.tr(.keySpace)
        }
    }

    var keyCode: Int {
        switch self {
        case .tab:      return Int(kVK_Tab)
        case .backtick: return Int(kVK_ANSI_Grave)
        case .space:    return Int(kVK_Space)
        }
    }
}

// MARK: - Settings model

@MainActor
final class SwitchBladeSettings: ObservableObject {
    static let shared = SwitchBladeSettings()

    private let ud = UserDefaults.standard

    // Switcher panel background color RGB
    @Published var bgRed: Double   { didSet { ud.set(bgRed,   forKey: "sb_bgR") } }
    @Published var bgGreen: Double { didSet { ud.set(bgGreen, forKey: "sb_bgG") } }
    @Published var bgBlue: Double  { didSet { ud.set(bgBlue,  forKey: "sb_bgB") } }

    // Switcher panel background opacity (0 – 1.0)
    @Published var backgroundOpacity: Double {
        didSet { ud.set(backgroundOpacity, forKey: "sb_bgOpacity") }
    }

    // Badge bar color RGB components (sRGB 0–1, pure black by default)
    @Published var badgeRed: Double   { didSet { ud.set(badgeRed,   forKey: "sb_badgeR") } }
    @Published var badgeGreen: Double { didSet { ud.set(badgeGreen, forKey: "sb_badgeG") } }
    @Published var badgeBlue: Double  { didSet { ud.set(badgeBlue,  forKey: "sb_badgeB") } }

    // Badge bar opacity (0 – 1)
    @Published var badgeOpacity: Double {
        didSet { ud.set(badgeOpacity, forKey: "sb_badgeOpacity") }
    }

    // Selection highlight color RGB components
    @Published var highlightRed: Double   { didSet { ud.set(highlightRed,   forKey: "sb_highlightR") } }
    @Published var highlightGreen: Double { didSet { ud.set(highlightGreen, forKey: "sb_highlightG") } }
    @Published var highlightBlue: Double  { didSet { ud.set(highlightBlue,  forKey: "sb_highlightB") } }
    @Published var highlightStrength: Double { didSet { ud.set(highlightStrength, forKey: "sb_highlightStrength") } }
    @Published var highlightOpacity: Double { didSet { ud.set(highlightOpacity, forKey: "sb_highlightOpacity") } }
    @Published var selectionEffect: SBSelectionEffect {
        didSet { ud.set(selectionEffect.rawValue, forKey: "sb_selectionEffect") }
    }

    // Preview tile minimum width in pts
    @Published var tileMinWidth: Double {
        didSet { ud.set(tileMinWidth, forKey: "sb_tileMinWidth") }
    }

    // Badge bar appearance
    @Published var badgeIconSize: Double {
        didSet { ud.set(badgeIconSize, forKey: "sb_badgeIconSize") }
    }
    @Published var badgeFontSize: Double {
        didSet { ud.set(badgeFontSize, forKey: "sb_badgeFontSize") }
    }
    @Published var badgeVerticalPadding: Double {
        didSet { ud.set(badgeVerticalPadding, forKey: "sb_badgeVPad") }
    }

    // Hotkey configuration
    @Published var modifier: SBModifier {
        didSet { ud.set(modifier.rawValue, forKey: "sb_modifier") }
    }
    @Published var triggerKey: SBTriggerKey {
        didSet { ud.set(triggerKey.rawValue, forKey: "sb_triggerKey") }
    }

    // Badge bar position
    @Published var badgePosition: SBBadgePosition {
        didSet { ud.set(badgePosition.rawValue, forKey: "sb_badgePosition") }
    }

    // Use each app's icon dominant color as badge background instead of a fixed color
    @Published var badgeUseAppColor: Bool {
        didSet { ud.set(badgeUseAppColor, forKey: "sb_badgeUseAppColor") }
    }

    // Interface language. Mirrors to LocalizationState.shared so non-actor
    // code paths (e.g. PermissionState.message) can localize without hopping
    // onto MainActor.
    @Published var language: AppLanguage {
        didSet {
            ud.set(language.rawValue, forKey: "sb_language")
            LocalizationState.shared.selection = language
        }
    }

    private init() {
        bgRed   = ud.object(forKey: "sb_bgR") as? Double ?? 0.0
        bgGreen = ud.object(forKey: "sb_bgG") as? Double ?? 0.0
        bgBlue  = ud.object(forKey: "sb_bgB") as? Double ?? 0.0
        backgroundOpacity = ud.object(forKey: "sb_bgOpacity") as? Double ?? 0.65
        badgeRed          = ud.object(forKey: "sb_badgeR")         as? Double ?? 0.0
        badgeGreen        = ud.object(forKey: "sb_badgeG")         as? Double ?? 0.0
        badgeBlue         = ud.object(forKey: "sb_badgeB")         as? Double ?? 0.0
        badgeOpacity      = ud.object(forKey: "sb_badgeOpacity")   as? Double ?? 0.72
        highlightRed      = ud.object(forKey: "sb_highlightR")     as? Double ?? 0.30
        highlightGreen    = ud.object(forKey: "sb_highlightG")     as? Double ?? 0.70
        highlightBlue     = ud.object(forKey: "sb_highlightB")     as? Double ?? 1.0
        highlightStrength = ud.object(forKey: "sb_highlightStrength") as? Double ?? 0.70
        highlightOpacity  = ud.object(forKey: "sb_highlightOpacity")  as? Double ?? 0.85
        tileMinWidth      = ud.object(forKey: "sb_tileMinWidth")   as? Double ?? 220.0
        modifier   = SBModifier(rawValue:   ud.string(forKey: "sb_modifier")   ?? "") ?? .command
        triggerKey = SBTriggerKey(rawValue: ud.string(forKey: "sb_triggerKey") ?? "") ?? .tab
        badgePosition = SBBadgePosition(rawValue: ud.string(forKey: "sb_badgePosition") ?? "") ?? .bottom
        selectionEffect = SBSelectionEffect(rawValue: ud.string(forKey: "sb_selectionEffect") ?? "") ?? .pump
        badgeIconSize       = ud.object(forKey: "sb_badgeIconSize") as? Double ?? 22.0
        badgeFontSize       = ud.object(forKey: "sb_badgeFontSize") as? Double ?? 11.0
        badgeVerticalPadding = ud.object(forKey: "sb_badgeVPad")   as? Double ?? 6.0
        badgeUseAppColor    = ud.object(forKey: "sb_badgeUseAppColor") as? Bool ?? false
        language = AppLanguage(rawValue: ud.string(forKey: "sb_language") ?? "") ?? .system
        // Mirror to the global LocalizationState immediately so first read on
        // launch is correct (didSet doesn't fire from this init).
        LocalizationState.shared.selection = language
    }

    /// Convenience SwiftUI Color for the badge bar background.
    var badgeColor: Color {
        Color(red: badgeRed, green: badgeGreen, blue: badgeBlue)
    }

    /// Convenience SwiftUI Color for the panel background.
    var backgroundColor: Color {
        Color(red: bgRed, green: bgGreen, blue: bgBlue)
    }

    /// Convenience SwiftUI Color for the selected tile highlight.
    var highlightColor: Color {
        Color(red: highlightRed, green: highlightGreen, blue: highlightBlue)
    }
}
