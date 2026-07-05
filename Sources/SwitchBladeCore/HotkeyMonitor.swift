import AppKit
import Carbon.HIToolbox
import os.log

@MainActor
final class HotkeyMonitor {
    enum TapRecoveryAction: Equatable {
        case noOp
        case reenable
        case rebuild
    }

    enum Direction: Equatable {
        case forward
        case backward
    }

    var onHotkey: ((Direction) -> Void)?
    var onCommandReleased: (() -> Void)?
    var onModifierDoubleTap: (() -> Void)?
    var onModifierMouseSwitch: (() -> Void)?
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
    private var tapWatchdogTask: Task<Void, Never>?
    private var wasHotkeyModifierDown = false

    private static let modifierDoubleTapThreshold: TimeInterval = 0.35
    private static let relevantShortcutFlags: CGEventFlags = [
        .maskCommand,
        .maskAlternate,
        .maskControl,
        .maskShift
    ]

    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Converts a `mach_absolute_time` delta into milliseconds. CGEvent.timestamp
    /// is mach_absolute_time at event creation — comparing it to now reveals how
    /// long the event sat in the system event queue before the tap callback
    /// dispatched it.
    static func machDeltaMilliseconds(from then: UInt64, to now: UInt64) -> Double {
        guard now >= then else {
            return 0
        }
        let delta = now - then
        let nanos = Double(delta) * Double(machTimebase.numer) / Double(machTimebase.denom)
        return nanos / 1_000_000
    }

    func start() {
        installEventTap()
        installEventMonitors()
        startTapWatchdog()
    }

    /// Tears down event tap and NSEvent monitors. Call before drop to guarantee
    /// no callback fires after the owner is gone (deinit is non-isolated and
    /// may race with the main RunLoop's tap callback otherwise).
    func stop() {
        tapWatchdogTask?.cancel()
        tapWatchdogTask = nil

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

    /// Periodic safety net: macOS can silently disable or invalidate an event
    /// tap without firing `.tapDisabledByTimeout`/`.tapDisabledByUserInput`
    /// (rare but observed under system stress). Polling every 5 s catches that
    /// and heals the tap — and the log line is the smoking gun if user-reported
    /// "Cmd+Tab did nothing for a few seconds" recurs.
    private func startTapWatchdog() {
        tapWatchdogTask?.cancel()
        tapWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.ensureEventTapReady(reason: "watchdog")
            }
        }
    }

    private func installEventTap() {
        guard eventTap == nil else {
            return
        }

        let unmanagedSelf = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let eventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)

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

    private func ensureEventTapReady(reason: String) {
        guard let eventTap else {
            Logger.hotkey.notice("Event tap missing at \(reason, privacy: .public) — reinstalling")
            installEventTap()
            return
        }

        let isPortValid = CFMachPortIsValid(eventTap)
        let isEnabled = isPortValid && CGEvent.tapIsEnabled(tap: eventTap)
        switch Self.tapRecoveryAction(isPortValid: isPortValid, isEnabled: isEnabled) {
        case .noOp:
            return
        case .reenable:
            Logger.hotkey.notice("Tap was disabled at \(reason, privacy: .public) — re-enabling")
            CGEvent.tapEnable(tap: eventTap, enable: true)
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                Logger.hotkey.notice("Tap stayed disabled after re-enable at \(reason, privacy: .public) — rebuilding")
                rebuildEventTap()
            }
        case .rebuild:
            Logger.hotkey.notice("Tap was invalid at \(reason, privacy: .public) — rebuilding")
            rebuildEventTap()
        }
    }

    static func tapRecoveryAction(isPortValid: Bool, isEnabled: Bool) -> TapRecoveryAction {
        if !isPortValid { return .rebuild }
        return isEnabled ? .noOp : .reenable
    }

    private func rebuildEventTap() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            self.eventTapSource = nil
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        installEventTap()
    }

    private func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            ensureEventTapReady(reason: "system callback \(type.rawValue)")
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            handleModifierFlagsChanged(
                flags: nsModifierFlags(from: event.flags),
                timestamp: Date.timeIntervalSinceReferenceDate,
                shouldHandleConfiguredRelease: true
            )
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown {
            return handleLeftMouseDown(event)
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
        guard let direction = Self.hotkeyDirection(
            keyCode: keyCode,
            flags: event.flags,
            configuredKey: configuredKey,
            hotkeyModifier: hotkeyModifier
        ) else {
            return Unmanaged.passUnretained(event)
        }

        armHotkeyModifierReleaseTrackingIfNeeded()
        let queueDelayMs = Self.machDeltaMilliseconds(from: event.timestamp, to: mach_absolute_time())
        PerformanceDiagnostics.record(
            "hotkey_event",
            fields: [
                "kind": .string("cmd_tab"),
                "queue_delay_ms": .double(queueDelayMs)
            ]
        )
        Logger.hotkey.notice(
            "Hotkey forwarded: \(String(describing: direction), privacy: .public) (queue delay \(queueDelayMs, format: .fixed(precision: 1), privacy: .public) ms)"
        )
        onHotkey?(direction)
        return nil
    }

    private func handleLeftMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let (isEnabled, doubleTapModifier) = MainActor.assumeIsolated {
            (
                SwitchBladeSettings.shared.doubleModifierSwitchEnabled,
                SwitchBladeSettings.shared.doubleModifier.cgFlag
            )
        }
        guard Self.shouldTriggerModifierMouseSwitch(
            isEnabled: isEnabled,
            flags: event.flags,
            doubleTapModifier: doubleTapModifier
        ) else {
            return Unmanaged.passUnretained(event)
        }

        // The double-tap modifier was used with a mouse button, so it was not
        // a standalone double-tap.
        lastTapModifierPressTimestamp = nil
        let queueDelayMs = Self.machDeltaMilliseconds(from: event.timestamp, to: mach_absolute_time())
        PerformanceDiagnostics.record(
            "hotkey_event",
            fields: [
                "kind": .string("modifier_mouse"),
                "queue_delay_ms": .double(queueDelayMs)
            ]
        )
        Logger.hotkey.info("Double-tap modifier + left mouse detected")
        onModifierMouseSwitch?()
        return nil
    }

    static func shouldTriggerModifierMouseSwitch(
        isEnabled: Bool,
        flags: CGEventFlags,
        doubleTapModifier: CGEventFlags
    ) -> Bool {
        guard isEnabled else { return false }
        return flags.intersection(relevantShortcutFlags) == doubleTapModifier
    }

    static func hotkeyDirection(
        keyCode: Int64,
        flags: CGEventFlags,
        configuredKey: Int,
        hotkeyModifier: CGEventFlags
    ) -> Direction? {
        guard keyCode == Int64(configuredKey) else { return nil }
        let relevantFlags = flags.intersection(relevantShortcutFlags)
        if relevantFlags == hotkeyModifier {
            return .forward
        }
        var backwardFlags = hotkeyModifier
        backwardFlags.insert(.maskShift)
        if relevantFlags == backwardFlags {
            return .backward
        }
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
        // NSEvent flag monitors fire independently of CGEventTap, so this is
        // the earliest moment we know the user touched a modifier — including
        // when the tap is silently disabled. Re-enable proactively before the
        // upcoming Tab key event reaches the system, otherwise macOS's own
        // Cmd+Tab switcher takes over until the 5s watchdog catches up.
        reenableTapIfDisabled(reason: "flagsChanged")
        handleModifierFlagsChanged(
            flags: event.modifierFlags,
            timestamp: Date.timeIntervalSinceReferenceDate,
            shouldHandleConfiguredRelease: true
        )
    }

    private func reenableTapIfDisabled(reason: String) {
        ensureEventTapReady(reason: reason)
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
        let isHotkeyModifierDown = flags.contains(hotkeyModifier)
        let isConfiguredModifierDown = flags.contains(doubleTapModifier)
        let companionFlags = flags.subtracting(doubleTapModifier)
        let isBareModifierPress = isConfiguredModifierDown && companionFlags.isEmpty

        if isConfiguredModifierDown && !isTapModifierPressed {
            handleTapModifierPress(timestamp: timestamp, isBareModifierPress: isBareModifierPress)
        } else if !isConfiguredModifierDown {
            isTapModifierPressed = false
        }

        defer {
            wasHotkeyModifierDown = isHotkeyModifierDown
        }

        guard shouldHandleConfiguredRelease,
              shouldTrackModifierRelease?() == true else {
            return
        }

        // Both the event tap and NSEvent monitors can deliver the same modifier
        // transition. Fire only on the actual down -> up edge so release
        // handling survives either source going missing without double-commit.
        if wasHotkeyModifierDown && !isHotkeyModifierDown {
            onCommandReleased?()
        }
    }

    private func armHotkeyModifierReleaseTrackingIfNeeded() {
        guard !wasHotkeyModifierDown else { return }
        Logger.hotkey.notice("Hotkey keyDown arrived without tracked modifier-down — arming release fallback")
        wasHotkeyModifierDown = true
    }

    func handleModifierFlagsChangedForTesting(
        flags: NSEvent.ModifierFlags,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate,
        shouldHandleConfiguredRelease: Bool
    ) {
        handleModifierFlagsChanged(
            flags: flags,
            timestamp: timestamp,
            shouldHandleConfiguredRelease: shouldHandleConfiguredRelease
        )
    }

    func armHotkeyModifierReleaseTrackingForTesting() {
        armHotkeyModifierReleaseTrackingIfNeeded()
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
