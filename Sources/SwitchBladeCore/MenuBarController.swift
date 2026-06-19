import AppKit
import Combine
import SwiftUI
import os.log

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindowController: NSWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private let secureInputMonitor: SecureInputMonitor
    private var secureInputWatchdogTask: Task<Void, Never>?
    private var secureInputState: SecureInputState = .inactive
    private weak var secureInputStatusMenuItem: NSMenuItem?
    private weak var secureInputCleanupMenuItem: NSMenuItem?

    init(secureInputMonitor: SecureInputMonitor = SecureInputMonitor()) {
        self.secureInputMonitor = secureInputMonitor
    }

    func setup() {
        secureInputState = secureInputMonitor.currentState()
        applyMenuBarVisibility(SwitchBladeSettings.shared.showMenuBarIcon)
        SwitchBladeSettings.shared.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] isVisible in
                self?.applyMenuBarVisibility(isVisible)
            }
            .store(in: &cancellables)
        startSecureInputWatchdog()
    }

    private func applyMenuBarVisibility(_ isVisible: Bool) {
        let shouldShow = isVisible || secureInputState.isActive
        if shouldShow {
            if statusItem == nil {
                installStatusItem()
            }
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeMenuBarIcon()
        item.button?.toolTip = menuBarToolTip(for: secureInputState)
        let menu = makeMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateSecureInputMenu()
    }

    /// Draws a custom template image: two small overlapping rounded rectangles
    /// (representing stacked windows) that reads clearly at 18×18pt in the menu bar.
    private func makeMenuBarIcon() -> NSImage {
        let size: CGFloat = 18
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.black.setFill()

            // Back window — top-right, smaller
            let back = CGRect(x: size * 0.32, y: size * 0.42, width: size * 0.60, height: size * 0.46)
            let backPath = NSBezierPath(roundedRect: back, xRadius: 2, yRadius: 2)
            ctx.setAlpha(0.55)
            backPath.fill()

            // Front window — bottom-left, larger
            let front = CGRect(x: size * 0.08, y: size * 0.12, width: size * 0.60, height: size * 0.46)
            let frontPath = NSBezierPath(roundedRect: front, xRadius: 2, yRadius: 2)
            ctx.setAlpha(1.0)
            frontPath.fill()

            // Title bar accent on front window
            let bar = CGRect(x: front.minX, y: front.maxY - front.height * 0.28,
                             width: front.width, height: front.height * 0.28)
            let barPath = NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2)
            ctx.setAlpha(0.3)
            barPath.fill()

            return true
        }
        img.isTemplate = true
        return img
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "SwitchBlade", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let secureInputStatus = NSMenuItem(title: secureInputStatusTitle(for: secureInputState), action: nil, keyEquivalent: "")
        secureInputStatus.isEnabled = false
        menu.addItem(secureInputStatus)
        secureInputStatusMenuItem = secureInputStatus

        let secureInputCleanup = NSMenuItem(
            title: L10n.tr(.menuSecureInputClear),
            action: #selector(clearStuckSecureInput),
            keyEquivalent: ""
        )
        secureInputCleanup.target = self
        menu.addItem(secureInputCleanup)
        secureInputCleanupMenuItem = secureInputCleanup

        menu.addItem(.separator())

        let settings = NSMenuItem(title: L10n.tr(.menuSettings), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let about = NSMenuItem(title: L10n.tr(.menuAbout), action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.tr(.menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshSecureInputState(reason: "menu")
    }

    @objc func openSettings() {
        if settingsWindowController == nil {
            let view = SettingsView(settings: SwitchBladeSettings.shared)
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.title = L10n.tr(.menuSettingsWindowTitle)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(host.view.fittingSize)
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: Self.aboutPanelOptions(bundleInfo: Bundle.main.infoDictionary ?? [:]))
    }

    @objc private func clearStuckSecureInput() {
        let result = secureInputMonitor.clearStuckSecureInput()
        secureInputState = result.after
        Logger.secureInput.notice(
            "Secure Input cleanup terminated \(result.terminated.count, privacy: .public) helper process(es); before=\(Self.logDescription(for: result.before), privacy: .public), after=\(Self.logDescription(for: result.after), privacy: .public)"
        )
        applyMenuBarVisibility(SwitchBladeSettings.shared.showMenuBarIcon)
        updateSecureInputMenu()
    }

    func windowWillClose(_ notification: Notification) {
        closeAuxiliaryPanels()
    }

    private func closeAuxiliaryPanels() {
        let colorPanel = NSColorPanel.shared
        colorPanel.orderOut(nil)
        colorPanel.close()
    }

    private func startSecureInputWatchdog() {
        secureInputWatchdogTask?.cancel()
        secureInputWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshSecureInputState(reason: "watchdog")
            }
        }
    }

    private func refreshSecureInputState(reason: String) {
        let previous = secureInputState
        let current = secureInputMonitor.currentState()
        secureInputState = current

        if previous != current {
            Logger.secureInput.notice(
                "Secure Input state changed at \(reason, privacy: .public): \(Self.logDescription(for: current), privacy: .public)"
            )
        }

        applyMenuBarVisibility(SwitchBladeSettings.shared.showMenuBarIcon)
        updateSecureInputMenu()
    }

    private func updateSecureInputMenu() {
        statusItem?.button?.toolTip = menuBarToolTip(for: secureInputState)
        statusItem?.button?.contentTintColor = secureInputState.isActive ? .systemOrange : nil

        secureInputStatusMenuItem?.title = secureInputStatusTitle(for: secureInputState)

        let targets = secureInputMonitor.safeCleanupTargets(for: secureInputState)
        secureInputCleanupMenuItem?.isEnabled = !targets.isEmpty
        secureInputCleanupMenuItem?.title = targets.isEmpty
            ? L10n.tr(.menuSecureInputClearUnavailable)
            : L10n.tr(.menuSecureInputClear)
    }

    private func secureInputStatusTitle(for state: SecureInputState) -> String {
        Self.secureInputStatusTitle(for: state, language: LocalizationState.effectiveLanguage)
    }

    private func menuBarToolTip(for state: SecureInputState) -> String {
        Self.secureInputToolTip(for: state, language: LocalizationState.effectiveLanguage)
    }

    static func secureInputStatusTitle(for state: SecureInputState, language: AppLanguage) -> String {
        guard let pid = state.pid else {
            return L10n.tr(.menuSecureInputOff, language: language)
        }
        if let process = state.process {
            return String(
                format: L10n.tr(.menuSecureInputActive, language: language),
                process.displayName,
                "\(pid)"
            )
        }
        return String(format: L10n.tr(.menuSecureInputStale, language: language), "\(pid)")
    }

    static func secureInputToolTip(for state: SecureInputState, language: AppLanguage) -> String {
        guard let pid = state.pid else {
            return "SwitchBlade"
        }
        if let process = state.process {
            return String(
                format: L10n.tr(.tooltipSecureInputActive, language: language),
                process.displayName,
                "\(pid)"
            )
        }
        return String(format: L10n.tr(.tooltipSecureInputStale, language: language), "\(pid)")
    }

    private static func logDescription(for state: SecureInputState) -> String {
        guard let pid = state.pid else { return "inactive" }
        if let process = state.process {
            return "active pid=\(pid) app=\(process.displayName)"
        }
        return "stale pid=\(pid)"
    }

    static func aboutPanelOptions(bundleInfo: [String: Any]) -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let versionString = aboutVersionString(bundleInfo: bundleInfo) {
            options[.applicationVersion] = versionString
        }
        if let timestampString = aboutTimestampString(bundleInfo: bundleInfo) {
            options[.credits] = NSAttributedString(string: timestampString)
        }
        return options
    }

    static func aboutVersionString(bundleInfo: [String: Any]) -> String? {
        let version = bundleInfo["CFBundleShortVersionString"] as? String

        return version.flatMap { value -> String? in
            guard !value.isEmpty else { return nil }
            return value
        }
    }

    static func aboutTimestampString(
        bundleInfo: [String: Any],
        timeZone: TimeZone = .autoupdatingCurrent,
        language: AppLanguage = LocalizationState.effectiveLanguage
    ) -> String? {
        let timestamp = bundleInfo["SwitchBladeBuildTimestamp"] as? String
        let timestampPart = timestamp.flatMap { rawTimestamp -> String? in
            guard !rawTimestamp.isEmpty else { return nil }
            let formattedTimestamp = formattedBuildTimestamp(
                from: rawTimestamp,
                timeZone: timeZone,
                language: language
            ) ?? rawTimestamp
            return "\(L10n.tr(.aboutBuiltAt, language: language)) \(formattedTimestamp)"
        }
        return timestampPart
    }

    static func formattedBuildTimestamp(
        from rawTimestamp: String,
        timeZone: TimeZone = .autoupdatingCurrent,
        language: AppLanguage = LocalizationState.effectiveLanguage
    ) -> String? {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: rawTimestamp) else { return nil }

        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        switch language {
        case .finnish:
            formatter.locale = Locale(identifier: "fi_FI")
            formatter.dateFormat = "d.M.yyyy 'klo' HH.mm"
        case .english, .system:
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
        }
        return formatter.string(from: date)
    }
}
