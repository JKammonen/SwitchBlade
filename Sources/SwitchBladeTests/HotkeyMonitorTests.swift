import CoreGraphics
import Foundation
@testable import SwitchBladeCore

enum HotkeyMonitorTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("HotkeyMonitor/modifierMouseSwitch_requiresSettingEnabled", modifierMouseSwitchRequiresSettingEnabled),
        ("HotkeyMonitor/modifierMouseSwitch_requiresDoubleTapModifier", modifierMouseSwitchRequiresDoubleTapModifier)
    ]

    @MainActor static func modifierMouseSwitchRequiresSettingEnabled() throws {
        try expect(!HotkeyMonitor.shouldTriggerModifierMouseSwitch(
            isEnabled: false,
            flags: [.maskCommand],
            doubleTapModifier: .maskCommand
        ))
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
}
