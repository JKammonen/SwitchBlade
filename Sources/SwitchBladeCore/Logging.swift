import os.log

/// Central os.Logger instances. View live in Console.app by filtering on
/// subsystem `com.jannekammonen.SwitchBlade`, or stream from the CLI:
///
///     log stream --predicate 'subsystem == "com.jannekammonen.SwitchBlade"'
///
/// Use the narrowest category that fits — keeps the Console.app sidebar clean
/// and makes filtering meaningful.
public extension Logger {
    private static let subsystem = "com.jannekammonen.SwitchBlade"

    /// AppDelegate lifecycle, permissions UI, top-level wiring.
    static let app         = Logger(subsystem: subsystem, category: "app")
    /// SwitcherStore cycle / hide / preview merge / MRU events.
    static let switcher    = Logger(subsystem: subsystem, category: "switcher")
    /// WindowCatalog: SCKit cache refresh, capture timing, capture failures.
    static let capture     = Logger(subsystem: subsystem, category: "capture")
    /// HotkeyMonitor event-tap setup and flag-release detection.
    static let hotkey      = Logger(subsystem: subsystem, category: "hotkey")
    /// Secure Event Input detection and safe helper cleanup.
    static let secureInput = Logger(subsystem: subsystem, category: "secure-input")
    /// WindowActivator AX raise/close paths.
    static let activator   = Logger(subsystem: subsystem, category: "activator")
    /// PermissionService state checks and prompt routing.
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
