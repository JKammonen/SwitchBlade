import AppKit
import Carbon.HIToolbox
import os.log

@MainActor
final class HotkeyMonitor {
    enum Direction {
        case forward
        case backward
    }

    var onHotkey: ((Direction) -> Void)?
    var onCommandReleased: (() -> Void)?
    var onModifierDoubleTap: (() -> Void)?
    var shouldTrackModifierRelease: (() -> Bool)?
    var onLocalKeyDown: ((NSEvent) -> Bool)?

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localKeyMonitor: Any?
    private var didInstallEventMonitors = false
    private var isTapModifierPressed = false
    private var lastTapModifierPressTimestamp: TimeInterval?

    private static let modifierDoubleTapThreshold: TimeInterval = 0.35

    func start() {
        installEventTap()
        installEventMonitors()
    }

    /// Tears down event tap and NSEvent monitors. Call before drop to guarantee
    /// no callback fires after the owner is gone (deinit is non-isolated and
    /// may race with the main RunLoop's tap callback otherwise).
    func stop() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            self.eventTapSource = nil
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }

        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }

        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }

        didInstallEventMonitors = false
    }

    // No deinit cleanup: Swift 6 disallows touching @MainActor properties from
    // a nonisolated deinit, and the prior race between the main RunLoop's tap
    // callback and an off-thread deinit was exactly what we're guarding against.
    // Owners MUST call stop() from MainActor before dropping the monitor.

    private func installEventTap() {
        guard eventTap == nil else {
            return
        }

        let unmanagedSelf = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handleEventTap(type: type, event: event)
            },
            userInfo: unmanagedSelf
        ) else {
            Logger.hotkey.error("CGEvent.tapCreate failed — Accessibility permission likely missing")
            return
        }

        let eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        self.eventTapSource = eventTapSource
        Logger.hotkey.info("Event tap installed")
    }

    private func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Logger.hotkey.notice("Event tap disabled by system (\(type.rawValue, privacy: .public)) — re-enabling")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }

            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            handleModifierFlagsChanged(
                flags: nsModifierFlags(from: event.flags),
                timestamp: Date.timeIntervalSinceReferenceDate,
                shouldHandleConfiguredRelease: false
            )
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Read configured hotkeys from settings; event tap runs on main RunLoop so assumeIsolated is safe.
        let (configuredKey, hotkeyModifier, doubleTapModifier) = MainActor.assumeIsolated {
            (
                SwitchBladeSettings.shared.triggerKey.keyCode,
                SwitchBladeSettings.shared.modifier.cgFlag,
                SwitchBladeSettings.shared.doubleModifier.cgFlag
            )
        }
        if event.flags.contains(doubleTapModifier) {
            // The double-tap modifier was used with another key, so it was not a standalone double-tap.
            lastTapModifierPressTimestamp = nil
        }
        let flags = event.flags.intersection([hotkeyModifier, .maskShift])
        guard keyCode == Int64(configuredKey), flags.contains(hotkeyModifier) else {
            return Unmanaged.passUnretained(event)
        }

        onHotkey?(flags.contains(.maskShift) ? .backward : .forward)
        return nil
    }

    private func installEventMonitors() {
        guard !didInstallEventMonitors else {
            return
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            return self.onLocalKeyDown?(event) == true ? nil : event
        }

        didInstallEventMonitors = true
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        handleModifierFlagsChanged(
            flags: event.modifierFlags,
            timestamp: Date.timeIntervalSinceReferenceDate,
            shouldHandleConfiguredRelease: true
        )
    }

    private func handleModifierFlagsChanged(
        flags rawFlags: NSEvent.ModifierFlags,
        timestamp: TimeInterval,
        shouldHandleConfiguredRelease: Bool
    ) {
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        let (hotkeyModifier, doubleTapModifier) = MainActor.assumeIsolated {
            (
                SwitchBladeSettings.shared.modifier.nsFlag,
                SwitchBladeSettings.shared.doubleModifier.nsFlag
            )
        }
        let isConfiguredModifierDown = flags.contains(doubleTapModifier)
        let companionFlags = flags.subtracting(doubleTapModifier)
        let isBareModifierPress = isConfiguredModifierDown && companionFlags.isEmpty

        if isConfiguredModifierDown && !isTapModifierPressed {
            handleTapModifierPress(timestamp: timestamp, isBareModifierPress: isBareModifierPress)
        } else if !isConfiguredModifierDown {
            isTapModifierPressed = false
        }

        guard shouldHandleConfiguredRelease else {
            return
        }

        guard shouldTrackModifierRelease?() == true else {
            return
        }

        // Use the configured modifier so release detection matches the active hotkey.
        if !flags.contains(hotkeyModifier) {
            onCommandReleased?()
        }
    }

    private func handleTapModifierPress(timestamp: TimeInterval, isBareModifierPress: Bool) {
        isTapModifierPressed = true

        guard isBareModifierPress else {
            lastTapModifierPressTimestamp = nil
            return
        }

        let isEnabled = MainActor.assumeIsolated { SwitchBladeSettings.shared.doubleModifierSwitchEnabled }
        guard isEnabled else {
            lastTapModifierPressTimestamp = nil
            return
        }

        if let lastTapModifierPressTimestamp,
           timestamp - lastTapModifierPressTimestamp <= Self.modifierDoubleTapThreshold {
            self.lastTapModifierPressTimestamp = nil
            Logger.hotkey.info("Double modifier tap detected")
            onModifierDoubleTap?()
            return
        }

        lastTapModifierPressTimestamp = timestamp
    }

    private func nsModifierFlags(from cgFlags: CGEventFlags) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if cgFlags.contains(.maskAlternate) { flags.insert(.option) }
        if cgFlags.contains(.maskCommand) { flags.insert(.command) }
        if cgFlags.contains(.maskControl) { flags.insert(.control) }
        if cgFlags.contains(.maskShift) { flags.insert(.shift) }
        if cgFlags.contains(.maskAlphaShift) { flags.insert(.capsLock) }
        if cgFlags.contains(.maskSecondaryFn) { flags.insert(.function) }
        return flags
    }
}
