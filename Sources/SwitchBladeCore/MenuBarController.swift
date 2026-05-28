import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindowController: NSWindowController?
    private var cancellables: Set<AnyCancellable> = []

    func setup() {
        applyMenuBarVisibility(SwitchBladeSettings.shared.showMenuBarIcon)
        SwitchBladeSettings.shared.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] isVisible in
                self?.applyMenuBarVisibility(isVisible)
            }
            .store(in: &cancellables)
    }

    private func applyMenuBarVisibility(_ isVisible: Bool) {
        if isVisible {
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
        item.menu = makeMenu()
        statusItem = item
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

    func windowWillClose(_ notification: Notification) {
        closeAuxiliaryPanels()
    }

    private func closeAuxiliaryPanels() {
        let colorPanel = NSColorPanel.shared
        colorPanel.orderOut(nil)
        colorPanel.close()
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
