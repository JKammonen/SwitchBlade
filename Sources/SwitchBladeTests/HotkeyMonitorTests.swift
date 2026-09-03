import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
@testable import SwitchBladeCore

enum HotkeyMonitorTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("HotkeyMonitor/commandRelease_firesOnModifierDownUpTransition", commandReleaseFiresOnTransition),
        ("HotkeyMonitor/commandRelease_duplicateReleaseDelivery_firesOnlyOnce", commandReleaseDuplicateDeliveryFiresOnce),
        ("HotkeyMonitor/commandRelease_keyDownWithoutPriorModifierDownStillFires", commandReleaseKeyDownWithoutPriorModifierDownStillFires),
        ("HotkeyMonitor/tapRecovery_rebuildsInvalidTap", tapRecoveryRebuildsInvalidTap),
        ("HotkeyMonitor/tapRecovery_reenablesValidDisabledTap", tapRecoveryReenablesValidDisabledTap),
        ("HotkeyMonitor/tapRecovery_leavesValidEnabledTapAlone", tapRecoveryLeavesValidEnabledTapAlone),
        ("HotkeyMonitor/modifierMouseSwitch_requiresSettingEnabled", modifierMouseSwitchRequiresSettingEnabled),
        ("HotkeyMonitor/modifierMouseSwitch_requiresDoubleTapModifier", modifierMouseSwitchRequiresDoubleTapModifier),
        ("HotkeyMonitor/modifierMouseSwitch_rejectsCompanionModifiers", modifierMouseSwitchRejectsCompanionModifiers),
        ("HotkeyMonitor/hotkeyDirection_allowsModifierAndShiftOnly", hotkeyDirectionAllowsModifierAndShiftOnly),
        ("HotkeyMonitor/hotkeyDirection_rejectsSupersetModifiers", hotkeyDirectionRejectsSupersetModifiers),
        ("HotkeyMonitor/machDelta_clampsFutureTimestamp", machDeltaClampsFutureTimestamp),
        ("HotkeyMonitor/passthroughReason_reportsSupersetModifiersOnly", passthroughReasonReportsSupersetModifiersOnly),
        ("HotkeyMonitor/secureInputProbe_throttlesToModifierDownInterval", secureInputProbeThrottlesToModifierDownInterval)
    ]

    @MainActor static func commandReleaseFiresOnTransition() throws {
        let settings = SwitchBladeSettings.shared
        let oldModifier = settings.modifier
        settings.modifier = .command
        defer { settings.modifier = oldModifier }

        let monitor = HotkeyMonitor()
        var releaseCount = 0
        monitor.shouldTrackModifierRelease = { true }
        monitor.onCommandReleased = { releaseCount += 1 }

        monitor.handleModifierFlagsChangedForTesting(flags: [.command], shouldHandleConfiguredRelease: true)
        monitor.handleModifierFlagsChangedForTesting(flags: [], shouldHandleConfiguredRelease: true)

        try expectEqual(releaseCount, 1)
    }

    @MainActor static func commandReleaseDuplicateDeliveryFiresOnce() throws {
        let settings = SwitchBladeSettings.shared
        let oldModifier = settings.modifier
        settings.modifier = .command
        defer { settings.modifier = oldModifier }

        let monitor = HotkeyMonitor()
        var releaseCount = 0
        monitor.shouldTrackModifierRelease = { true }
        monitor.onCommandReleased = { releaseCount += 1 }

        monitor.handleModifierFlagsChangedForTesting(flags: [.command], shouldHandleConfiguredRelease: true)
        monitor.handleModifierFlagsChangedForTesting(flags: [], shouldHandleConfiguredRelease: true)
        monitor.handleModifierFlagsChangedForTesting(flags: [], shouldHandleConfiguredRelease: true)

        try expectEqual(releaseCount, 1)
    }

    @MainActor static func commandReleaseKeyDownWithoutPriorModifierDownStillFires() throws {
        let settings = SwitchBladeSettings.shared
        let oldModifier = settings.modifier
        settings.modifier = .command
        defer { settings.modifier = oldModifier }

        let monitor = HotkeyMonitor()
        var releaseCount = 0
        monitor.shouldTrackModifierRelease = { true }
        monitor.onCommandReleased = { releaseCount += 1 }

        monitor.armHotkeyModifierReleaseTrackingForTesting()
        monitor.handleModifierFlagsChangedForTesting(flags: [], shouldHandleConfiguredRelease: true)

        try expectEqual(releaseCount, 1)
    }

    @MainActor static func modifierMouseSwitchRequiresSettingEnabled() throws {
        try expect(!HotkeyMonitor.shouldTriggerModifierMouseSwitch(
            isEnabled: false,
            flags: [.maskCommand],
            doubleTapModifier: .maskCommand
        ))
    }

    @MainActor static func tapRecoveryRebuildsInvalidTap() throws {
        try expectEqual(
            HotkeyMonitor.tapRecoveryAction(isPortValid: false, isEnabled: false),
            .rebuild
        )
        try expectEqual(
            HotkeyMonitor.tapRecoveryAction(isPortValid: false, isEnabled: true),
            .rebuild
        )
    }

    @MainActor static func tapRecoveryReenablesValidDisabledTap() throws {
        try expectEqual(
            HotkeyMonitor.tapRecoveryAction(isPortValid: true, isEnabled: false),
            .reenable
        )
    }

    @MainActor static func tapRecoveryLeavesValidEnabledTapAlone() throws {
        try expectEqual(
            HotkeyMonitor.tapRecoveryAction(isPortValid: true, isEnabled: true),
            .noOp
        )
    }

    @MainActor static func modifierMouseSwitchRequiresDoubleTapModifier() throws {
        try expect(HotkeyMonitor.shouldTriggerModifierMouseSwitch(
            isEnabled: true,
            flags: [.maskAlternate],
            doubleTapModifier: .maskAlternate
        ))
        try expect(!HotkeyMonitor.shouldTriggerModifierMouseSwitch(
            isEnabled: true,
            flags: [.maskCommand],
            doubleTapModifier: .maskAlternate
        ))
    }

    @MainActor static func modifierMouseSwitchRejectsCompanionModifiers() throws {
        try expect(!HotkeyMonitor.shouldTriggerModifierMouseSwitch(
            isEnabled: true,
            flags: [.maskCommand, .maskShift],
            doubleTapModifier: .maskCommand
        ))
    }

    @MainActor static func hotkeyDirectionAllowsModifierAndShiftOnly() throws {
        try expectEqual(
            HotkeyMonitor.hotkeyDirection(
                keyCode: Int64(kVK_Tab),
                flags: [.maskCommand],
                configuredKey: Int(kVK_Tab),
                hotkeyModifier: .maskCommand
            ),
            .forward
        )
        try expectEqual(
            HotkeyMonitor.hotkeyDirection(
                keyCode: Int64(kVK_Tab),
                flags: [.maskCommand, .maskShift],
                configuredKey: Int(kVK_Tab),
                hotkeyModifier: .maskCommand
            ),
            .backward
        )
    }

    @MainActor static func hotkeyDirectionRejectsSupersetModifiers() throws {
        try expectNil(HotkeyMonitor.hotkeyDirection(
            keyCode: Int64(kVK_Tab),
            flags: [.maskCommand, .maskControl],
            configuredKey: Int(kVK_Tab),
            hotkeyModifier: .maskCommand
        ))
        try expectNil(HotkeyMonitor.hotkeyDirection(
            keyCode: Int64(kVK_Tab),
            flags: [.maskCommand, .maskAlternate, .maskShift],
            configuredKey: Int(kVK_Tab),
            hotkeyModifier: .maskCommand
        ))
    }

    /// Proves: a trigger-key press with the hotkey modifier plus extra Ctrl or
    /// Option flags is reported as a superset pass-through, while an exact
    /// match, a different key, or a modifier-less press stays silent.
    @MainActor static func passthroughReasonReportsSupersetModifiersOnly() throws {
        try expectEqual(
            HotkeyMonitor.passthroughReason(
                keyCode: Int64(kVK_Tab),
                flags: [.maskCommand, .maskControl],
                configuredKey: Int(kVK_Tab),
                hotkeyModifier: .maskCommand
            ),
            .supersetModifiers
        )
        try expectEqual(
            HotkeyMonitor.passthroughReason(
                keyCode: Int64(kVK_Tab),
                flags: [.maskCommand, .maskAlternate, .maskShift],
                configuredKey: Int(kVK_Tab),
                hotkeyModifier: .maskCommand
            ),
            .supersetModifiers
        )
        try expectNil(HotkeyMonitor.passthroughReason(
            keyCode: Int64(kVK_Tab),
            flags: [.maskCommand],
            configuredKey: Int(kVK_Tab),
            hotkeyModifier: .maskCommand
        ))
        try expectNil(HotkeyMonitor.passthroughReason(
            keyCode: Int64(kVK_Tab),
            flags: [.maskCommand, .maskShift],
            configuredKey: Int(kVK_Tab),
            hotkeyModifier: .maskCommand
        ))
        try expectNil(HotkeyMonitor.passthroughReason(
            keyCode: Int64(kVK_Space),
            flags: [.maskCommand, .maskControl],
            configuredKey: Int(kVK_Tab),
            hotkeyModifier: .maskCommand
        ))
        try expectNil(HotkeyMonitor.passthroughReason(
            keyCode: Int64(kVK_Tab),
            flags: [.maskControl],
            configuredKey: Int(kVK_Tab),
            hotkeyModifier: .maskCommand
        ))
    }

    /// Proves: the probe throttle predicate answers true only while the hotkey
    /// modifier is down and at least one interval after the last probe. The
    /// wiring that stores the probe time lives in `probeSecureInputIfNeeded`
    /// and is not exercised here.
    @MainActor static func secureInputProbeThrottlesToModifierDownInterval() throws {
        try expect(HotkeyMonitor.shouldProbeSecureInput(
            isHotkeyModifierDown: true,
            lastProbeAt: -.infinity,
            now: 100
        ))
        try expect(!HotkeyMonitor.shouldProbeSecureInput(
            isHotkeyModifierDown: false,
            lastProbeAt: -.infinity,
            now: 100
        ))
        try expect(!HotkeyMonitor.shouldProbeSecureInput(
            isHotkeyModifierDown: true,
            lastProbeAt: 100,
            now: 100 + HotkeyMonitor.secureInputProbeInterval / 2
        ))
        try expect(HotkeyMonitor.shouldProbeSecureInput(
            isHotkeyModifierDown: true,
            lastProbeAt: 100,
            now: 100 + HotkeyMonitor.secureInputProbeInterval
        ))
    }

    @MainActor static func machDeltaClampsFutureTimestamp() throws {
        try expectEqual(
            HotkeyMonitor.machDeltaMilliseconds(from: 2_000, to: 1_000),
            0
        )
        try expectGreaterThan(
            HotkeyMonitor.machDeltaMilliseconds(from: 1_000, to: 2_000),
            0
        )
    }
}
