import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ServiceManagement
import SwiftUI
import os.log

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

enum ReservedShortcutConflict: Equatable, Sendable {
    case spotlight
    case inputSource

    var message: String {
        switch self {
        case .spotlight:
            return L10n.tr(.shortcutConflictSpotlight)
        case .inputSource:
            return L10n.tr(.shortcutConflictInputSource)
        }
    }
}

enum ShortcutConflictPolicy {
    /// SwitchBlade must not silently steal system-wide shortcuts that macOS
    /// reserves by default. Command-Tab is intentionally supported because
    /// replacing that switcher is the app's purpose; Space combinations are not.
    static func conflict(modifier: SBModifier, triggerKey: SBTriggerKey) -> ReservedShortcutConflict? {
        guard triggerKey == .space else { return nil }
        switch modifier {
        case .command:
            return .spotlight
        case .control:
            return .inputSource
        case .option:
            return nil
        }
    }
}

// MARK: - Settings model

@MainActor
final class SwitchBladeSettings: ObservableObject {
    static let shared = SwitchBladeSettings()

    private let ud: UserDefaults
    private let launchAtLoginController: LaunchAtLoginController
    private var isSyncingLaunchAtLogin = false

    // Switcher panel background color RGB
    private var bgRedValue: Double
    private var bgGreenValue: Double
    private var bgBlueValue: Double
    var bgRed: Double {
        get { bgRedValue }
        set { bgRedValue = updateNumeric(newValue, current: bgRedValue, in: 0...1, fallback: 0, key: "sb_bgR") }
    }
    var bgGreen: Double {
        get { bgGreenValue }
        set { bgGreenValue = updateNumeric(newValue, current: bgGreenValue, in: 0...1, fallback: 0, key: "sb_bgG") }
    }
    var bgBlue: Double {
        get { bgBlueValue }
        set { bgBlueValue = updateNumeric(newValue, current: bgBlueValue, in: 0...1, fallback: 0, key: "sb_bgB") }
    }

    // Switcher panel background opacity (0 – 1.0)
    private var backgroundOpacityValue: Double
    var backgroundOpacity: Double {
        get { backgroundOpacityValue }
        set { backgroundOpacityValue = updateNumeric(newValue, current: backgroundOpacityValue, in: 0...1, fallback: 0.65, key: "sb_bgOpacity") }
    }

    // Badge bar color RGB components (sRGB 0–1, pure black by default)
    private var badgeRedValue: Double
    private var badgeGreenValue: Double
    private var badgeBlueValue: Double
    var badgeRed: Double {
        get { badgeRedValue }
        set { badgeRedValue = updateNumeric(newValue, current: badgeRedValue, in: 0...1, fallback: 0, key: "sb_badgeR") }
    }
    var badgeGreen: Double {
        get { badgeGreenValue }
        set { badgeGreenValue = updateNumeric(newValue, current: badgeGreenValue, in: 0...1, fallback: 0, key: "sb_badgeG") }
    }
    var badgeBlue: Double {
        get { badgeBlueValue }
        set { badgeBlueValue = updateNumeric(newValue, current: badgeBlueValue, in: 0...1, fallback: 0, key: "sb_badgeB") }
    }

    // Badge bar opacity (0 – 1)
    private var badgeOpacityValue: Double
    var badgeOpacity: Double {
        get { badgeOpacityValue }
        set { badgeOpacityValue = updateNumeric(newValue, current: badgeOpacityValue, in: 0...1, fallback: 0.72, key: "sb_badgeOpacity") }
    }

    // Selection highlight color RGB components
    private var highlightRedValue: Double
    private var highlightGreenValue: Double
    private var highlightBlueValue: Double
    private var highlightStrengthValue: Double
    private var highlightOpacityValue: Double
    var highlightRed: Double {
        get { highlightRedValue }
        set { highlightRedValue = updateNumeric(newValue, current: highlightRedValue, in: 0...1, fallback: 0.30, key: "sb_highlightR") }
    }
    var highlightGreen: Double {
        get { highlightGreenValue }
        set { highlightGreenValue = updateNumeric(newValue, current: highlightGreenValue, in: 0...1, fallback: 0.70, key: "sb_highlightG") }
    }
    var highlightBlue: Double {
        get { highlightBlueValue }
        set { highlightBlueValue = updateNumeric(newValue, current: highlightBlueValue, in: 0...1, fallback: 1, key: "sb_highlightB") }
    }
    var highlightStrength: Double {
        get { highlightStrengthValue }
        set { highlightStrengthValue = updateNumeric(newValue, current: highlightStrengthValue, in: 0.2...1, fallback: 0.70, key: "sb_highlightStrength") }
    }
    var highlightOpacity: Double {
        get { highlightOpacityValue }
        set { highlightOpacityValue = updateNumeric(newValue, current: highlightOpacityValue, in: 0.15...1, fallback: 0.85, key: "sb_highlightOpacity") }
    }
    @Published var selectionEffect: SBSelectionEffect {
        didSet { ud.set(selectionEffect.rawValue, forKey: "sb_selectionEffect") }
    }

    // Preview tile width in pts and switcher maximum width as a screen fraction
    private var tileMinWidthValue: Double
    private var selectorWidthFractionValue: Double
    var tileMinWidth: Double {
        get { tileMinWidthValue }
        set { tileMinWidthValue = updateNumeric(newValue, current: tileMinWidthValue, in: 140...380, fallback: 220, key: "sb_tileMinWidth") }
    }
    var selectorWidthFraction: Double {
        get { selectorWidthFractionValue }
        set { selectorWidthFractionValue = updateNumeric(newValue, current: selectorWidthFractionValue, in: 0.5...0.95, fallback: 0.8, key: "sb_selectorWidthFraction") }
    }

    // Badge bar appearance
    private var badgeIconSizeValue: Double
    private var badgeFontSizeValue: Double
    private var badgeVerticalPaddingValue: Double
    var badgeIconSize: Double {
        get { badgeIconSizeValue }
        set { badgeIconSizeValue = updateNumeric(newValue, current: badgeIconSizeValue, in: 12...32, fallback: 22, key: "sb_badgeIconSize") }
    }
    var badgeFontSize: Double {
        get { badgeFontSizeValue }
        set { badgeFontSizeValue = updateNumeric(newValue, current: badgeFontSizeValue, in: 9...16, fallback: 11, key: "sb_badgeFontSize") }
    }
    var badgeVerticalPadding: Double {
        get { badgeVerticalPaddingValue }
        set { badgeVerticalPaddingValue = updateNumeric(newValue, current: badgeVerticalPaddingValue, in: 2...14, fallback: 6, key: "sb_badgeVPad") }
    }

    // Hotkey configuration
    @Published var modifier: SBModifier {
        didSet {
            if let conflict = ShortcutConflictPolicy.conflict(modifier: modifier, triggerKey: triggerKey) {
                modifier = oldValue
                shortcutConflict = conflict
            } else {
                shortcutConflict = nil
                ud.set(modifier.rawValue, forKey: "sb_modifier")
            }
        }
    }
    @Published var triggerKey: SBTriggerKey {
        didSet {
            if let conflict = ShortcutConflictPolicy.conflict(modifier: modifier, triggerKey: triggerKey) {
                triggerKey = oldValue
                shortcutConflict = conflict
            } else {
                shortcutConflict = nil
                ud.set(triggerKey.rawValue, forKey: "sb_triggerKey")
            }
        }
    }
    @Published private(set) var shortcutConflict: ReservedShortcutConflict? = nil
    @Published var doubleModifierSwitchEnabled: Bool {
        // Keep the legacy key name so existing user preferences survive the rename
        // from "double Option" to "double configured modifier".
        didSet { ud.set(doubleModifierSwitchEnabled, forKey: "sb_doubleOptionSwitchEnabled") }
    }
    @Published var doubleModifier: SBModifier {
        didSet { ud.set(doubleModifier.rawValue, forKey: "sb_doubleModifier") }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            if isSyncingLaunchAtLogin {
                ud.set(launchAtLogin, forKey: "sb_launchAtLogin")
                return
            }
            applyLaunchAtLoginChange(requestedEnabled: launchAtLogin)
        }
    }
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus

    @Published var showMenuBarIcon: Bool {
        didSet { ud.set(showMenuBarIcon, forKey: "sb_showMenuBarIcon") }
    }

    @Published var windowScope: SBWindowScope {
        didSet {
            ud.set(windowScope.rawValue, forKey: "sb_windowScope")
            // Keep the legacy key mirrored for users downgrading builds and for
            // any older code path still reading the boolean.
            ud.set(windowScope == .currentSpace, forKey: "sb_restrictToCurrentSpace")
            WindowFilterState.scope = windowScope
        }
    }

    @Published var previewMode: SBPreviewMode {
        didSet { ud.set(previewMode.rawValue, forKey: "sb_previewMode") }
    }

    @Published var sortOrder: SBSortOrder {
        didSet { ud.set(sortOrder.rawValue, forKey: "sb_sortOrder") }
    }

    @Published var hiddenAppsText: String {
        didSet {
            ud.set(hiddenAppsText, forKey: "sb_hiddenAppsText")
            HiddenAppFilterState.normalizedTokens = Self.normalizedHiddenAppTokens(from: hiddenAppsText)
        }
    }

    @Published var reducedMotion: Bool {
        didSet { ud.set(reducedMotion, forKey: "sb_reducedMotion") }
    }

    @Published var performanceLogging: SBPerformanceLogging {
        didSet {
            ud.set(performanceLogging.rawValue, forKey: "sb_performanceLogging")
            PerformanceLoggingState.mode = performanceLogging
        }
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
            LocalizationState.selection = language
        }
    }

    // Compatibility wrapper for older code/tests: true maps to current Space,
    // false maps to all Spaces. New UI should bind to `windowScope`.
    var restrictToCurrentSpace: Bool {
        get { windowScope == .currentSpace }
        set { windowScope = newValue ? .currentSpace : .allSpaces }
    }

    init(
        userDefaults: UserDefaults = .standard,
        launchAtLoginController: LaunchAtLoginController = .system
    ) {
        self.ud = userDefaults
        self.launchAtLoginController = launchAtLoginController

        bgRedValue = Self.sanitizedNumeric(ud.object(forKey: "sb_bgR") as? Double, in: 0...1, fallback: 0)
        bgGreenValue = Self.sanitizedNumeric(ud.object(forKey: "sb_bgG") as? Double, in: 0...1, fallback: 0)
        bgBlueValue = Self.sanitizedNumeric(ud.object(forKey: "sb_bgB") as? Double, in: 0...1, fallback: 0)
        backgroundOpacityValue = Self.sanitizedNumeric(ud.object(forKey: "sb_bgOpacity") as? Double, in: 0...1, fallback: 0.65)
        badgeRedValue = Self.sanitizedNumeric(ud.object(forKey: "sb_badgeR") as? Double, in: 0...1, fallback: 0)
        badgeGreenValue = Self.sanitizedNumeric(ud.object(forKey: "sb_badgeG") as? Double, in: 0...1, fallback: 0)
        badgeBlueValue = Self.sanitizedNumeric(ud.object(forKey: "sb_badgeB") as? Double, in: 0...1, fallback: 0)
        badgeOpacityValue = Self.sanitizedNumeric(ud.object(forKey: "sb_badgeOpacity") as? Double, in: 0...1, fallback: 0.72)
        highlightRedValue = Self.sanitizedNumeric(ud.object(forKey: "sb_highlightR") as? Double, in: 0...1, fallback: 0.30)
        highlightGreenValue = Self.sanitizedNumeric(ud.object(forKey: "sb_highlightG") as? Double, in: 0...1, fallback: 0.70)
        highlightBlueValue = Self.sanitizedNumeric(ud.object(forKey: "sb_highlightB") as? Double, in: 0...1, fallback: 1)
        highlightStrengthValue = Self.sanitizedNumeric(ud.object(forKey: "sb_highlightStrength") as? Double, in: 0.2...1, fallback: 0.70)
        highlightOpacityValue = Self.sanitizedNumeric(ud.object(forKey: "sb_highlightOpacity") as? Double, in: 0.15...1, fallback: 0.85)
        tileMinWidthValue = Self.sanitizedNumeric(ud.object(forKey: "sb_tileMinWidth") as? Double, in: 140...380, fallback: 220)
        selectorWidthFractionValue = Self.sanitizedNumeric(ud.object(forKey: "sb_selectorWidthFraction") as? Double, in: 0.5...0.95, fallback: 0.8)
        let storedModifier = SBModifier(rawValue: ud.string(forKey: "sb_modifier") ?? "") ?? .command
        let storedTriggerKey = SBTriggerKey(rawValue: ud.string(forKey: "sb_triggerKey") ?? "") ?? .tab
        if ShortcutConflictPolicy.conflict(modifier: storedModifier, triggerKey: storedTriggerKey) == nil {
            modifier = storedModifier
            triggerKey = storedTriggerKey
        } else {
            modifier = .command
            triggerKey = .tab
        }
        doubleModifierSwitchEnabled = ud.object(forKey: "sb_doubleOptionSwitchEnabled") as? Bool ?? false
        doubleModifier = SBModifier(rawValue: ud.string(forKey: "sb_doubleModifier") ?? "") ?? .command
        let currentLaunchStatus = launchAtLoginController.currentStatus()
        launchAtLoginStatus = currentLaunchStatus
        launchAtLogin = currentLaunchStatus.isEnabled
        ud.set(currentLaunchStatus.isEnabled, forKey: "sb_launchAtLogin")
        showMenuBarIcon = ud.object(forKey: "sb_showMenuBarIcon") as? Bool ?? true
        if let rawScope = ud.string(forKey: "sb_windowScope"),
           let storedScope = SBWindowScope(rawValue: rawScope) {
            windowScope = storedScope
        } else {
            let legacyRestrict = ud.object(forKey: "sb_restrictToCurrentSpace") as? Bool ?? true
            windowScope = legacyRestrict ? .currentSpace : .allSpaces
        }
        previewMode = SBPreviewMode(rawValue: ud.string(forKey: "sb_previewMode") ?? "") ?? .livePreviews
        sortOrder = SBSortOrder(rawValue: ud.string(forKey: "sb_sortOrder") ?? "") ?? .recentlyUsed
        hiddenAppsText = ud.string(forKey: "sb_hiddenAppsText") ?? ""
        reducedMotion = ud.object(forKey: "sb_reducedMotion") as? Bool ?? false
        performanceLogging = SBPerformanceLogging(rawValue: ud.string(forKey: "sb_performanceLogging") ?? "") ?? .basic
        badgePosition = SBBadgePosition(rawValue: ud.string(forKey: "sb_badgePosition") ?? "") ?? .bottom
        selectionEffect = SBSelectionEffect(rawValue: ud.string(forKey: "sb_selectionEffect") ?? "") ?? .pump
        badgeIconSizeValue = Self.sanitizedNumeric(ud.object(forKey: "sb_badgeIconSize") as? Double, in: 12...32, fallback: 22)
        badgeFontSizeValue = Self.sanitizedNumeric(ud.object(forKey: "sb_badgeFontSize") as? Double, in: 9...16, fallback: 11)
        badgeVerticalPaddingValue = Self.sanitizedNumeric(ud.object(forKey: "sb_badgeVPad") as? Double, in: 2...14, fallback: 6)
        badgeUseAppColor    = ud.object(forKey: "sb_badgeUseAppColor") as? Bool ?? false
        language = AppLanguage(rawValue: ud.string(forKey: "sb_language") ?? "") ?? .system
        // Mirror to the global LocalizationState immediately so first read on
        // launch is correct (didSet doesn't fire from this init).
        LocalizationState.selection = language
        WindowFilterState.scope = windowScope
        HiddenAppFilterState.normalizedTokens = Self.normalizedHiddenAppTokens(from: hiddenAppsText)
        PerformanceLoggingState.mode = performanceLogging
        persistCurrentNumericValues()
        ud.set(modifier.rawValue, forKey: "sb_modifier")
        ud.set(triggerKey.rawValue, forKey: "sb_triggerKey")
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

    func resetAppearanceDefaults() {
        bgRed = 0.0
        bgGreen = 0.0
        bgBlue = 0.0
        backgroundOpacity = 0.65
        badgeRed = 0.0
        badgeGreen = 0.0
        badgeBlue = 0.0
        badgeOpacity = 0.72
        badgePosition = .bottom
        badgeUseAppColor = false
        badgeIconSize = 22.0
        badgeFontSize = 11.0
        badgeVerticalPadding = 6.0
        highlightRed = 0.30
        highlightGreen = 0.70
        highlightBlue = 1.0
        highlightStrength = 0.70
        highlightOpacity = 0.85
        selectionEffect = .pump
        tileMinWidth = 220.0
        selectorWidthFraction = 0.8
        previewMode = .livePreviews
        reducedMotion = false
    }

    func refreshLaunchAtLoginStatus() {
        let current = launchAtLoginController.currentStatus()
        launchAtLoginStatus = current
        syncLaunchAtLoginValue(current.isEnabled)
    }

    var hiddenAppRuleCounts: (substring: Int, exact: Int) {
        Self.normalizedHiddenAppTokens(from: hiddenAppsText).reduce(into: (substring: 0, exact: 0)) { counts, token in
            switch token {
            case .contains:
                counts.substring += 1
            case .exact:
                counts.exact += 1
            }
        }
    }

    private func applyLaunchAtLoginChange(requestedEnabled: Bool) {
        switch launchAtLoginController.setEnabled(requestedEnabled) {
        case .success(let status):
            launchAtLoginStatus = status
            syncLaunchAtLoginValue(status.isEnabled)
        case .failure(let failure):
            Logger.app.error("Launch at login update failed: \(failure.message, privacy: .public)")
            launchAtLoginStatus = .updateFailed
            let actualStatus = launchAtLoginController.currentStatus()
            syncLaunchAtLoginValue(actualStatus.isEnabled)
        }
    }

    private func syncLaunchAtLoginValue(_ enabled: Bool) {
        if launchAtLogin == enabled {
            ud.set(enabled, forKey: "sb_launchAtLogin")
            return
        }
        isSyncingLaunchAtLogin = true
        launchAtLogin = enabled
        isSyncingLaunchAtLogin = false
    }

    private static func sanitizedNumeric(
        _ value: Double?,
        in range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func updateNumeric(
        _ proposedValue: Double,
        current currentValue: Double,
        in range: ClosedRange<Double>,
        fallback: Double,
        key: String
    ) -> Double {
        let sanitized = Self.sanitizedNumeric(proposedValue, in: range, fallback: fallback)
        if sanitized != currentValue {
            objectWillChange.send()
        }
        ud.set(sanitized, forKey: key)
        return sanitized
    }

    private func persistCurrentNumericValues() {
        ud.set(bgRed, forKey: "sb_bgR")
        ud.set(bgGreen, forKey: "sb_bgG")
        ud.set(bgBlue, forKey: "sb_bgB")
        ud.set(backgroundOpacity, forKey: "sb_bgOpacity")
        ud.set(badgeRed, forKey: "sb_badgeR")
        ud.set(badgeGreen, forKey: "sb_badgeG")
        ud.set(badgeBlue, forKey: "sb_badgeB")
        ud.set(badgeOpacity, forKey: "sb_badgeOpacity")
        ud.set(highlightRed, forKey: "sb_highlightR")
        ud.set(highlightGreen, forKey: "sb_highlightG")
        ud.set(highlightBlue, forKey: "sb_highlightB")
        ud.set(highlightStrength, forKey: "sb_highlightStrength")
        ud.set(highlightOpacity, forKey: "sb_highlightOpacity")
        ud.set(tileMinWidth, forKey: "sb_tileMinWidth")
        ud.set(selectorWidthFraction, forKey: "sb_selectorWidthFraction")
        ud.set(badgeIconSize, forKey: "sb_badgeIconSize")
        ud.set(badgeFontSize, forKey: "sb_badgeFontSize")
        ud.set(badgeVerticalPadding, forKey: "sb_badgeVPad")
    }

    /// Parses the comma/semicolon/newline-separated hidden-apps field.
    /// Bare tokens become `.contains`; a leading `=` makes the rule exact.
    /// `=` with no body, or empty entries, are silently dropped.
    static func normalizedHiddenAppTokens(from text: String) -> Set<HiddenAppToken> {
        let separators = CharacterSet(charactersIn: ",;\n")
        return Set(text
            .components(separatedBy: separators)
            .compactMap { raw -> HiddenAppToken? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if trimmed.hasPrefix("=") {
                    let body = trimmed.dropFirst()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    // `==`, `===`, etc. are silently dropped — only one leading
                    // `=` is meaningful, and a body that's still `=`-prefixed
                    // can never match a real app or bundle identifier.
                    guard !body.isEmpty, !body.hasPrefix("=") else { return nil }
                    return .exact(body)
                }
                return .contains(trimmed.lowercased())
            })
    }
}

enum LaunchAtLoginStatus: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
    case updateFailed

    var isEnabled: Bool {
        self == .enabled
    }

    var allowsUserToggle: Bool {
        self != .unavailable
    }

    var isFailure: Bool {
        self == .updateFailed
    }

    var title: String {
        switch self {
        case .enabled:
            return L10n.tr(.launchAtLoginStatusEnabled)
        case .disabled:
            return L10n.tr(.launchAtLoginStatusDisabled)
        case .requiresApproval:
            return L10n.tr(.launchAtLoginStatusRequiresApproval)
        case .unavailable:
            return L10n.tr(.launchAtLoginStatusUnavailable)
        case .updateFailed:
            return L10n.tr(.launchAtLoginStatusUpdateFailed)
        }
    }
}

struct LaunchAtLoginUpdateFailure: Error, Equatable {
    let message: String
}

/// Main-actor settings own this controller. The unchecked marker keeps the static
/// system instance Swift-6-clean while still allowing tests to inject local fakes.
struct LaunchAtLoginController: @unchecked Sendable {
    let currentStatus: () -> LaunchAtLoginStatus
    let setEnabled: (Bool) -> Result<LaunchAtLoginStatus, LaunchAtLoginUpdateFailure>

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static let system = LaunchAtLoginController(
        currentStatus: {
            guard #available(macOS 13.0, *) else { return .unavailable }
            return status(from: SMAppService.mainApp.status)
        },
        setEnabled: { enabled in
            guard #available(macOS 13.0, *) else { return .success(.unavailable) }

            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                return .success(status(from: SMAppService.mainApp.status))
            } catch {
                return .failure(LaunchAtLoginUpdateFailure(message: error.localizedDescription))
            }
        }
    )

    @available(macOS 13.0, *)
    private static func status(from status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .disabled
        @unknown default:
            return .disabled
        }
    }
}
