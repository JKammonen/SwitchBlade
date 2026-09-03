import AppKit
import Combine
import SwiftUI
import os.log

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindowController: NSWindowController?
    private var settingsHostingController: NSHostingController<SettingsView>?
    private var cancellables: Set<AnyCancellable> = []
    private let secureInputMonitor: SecureInputMonitor
    private var secureInputWatchdogTask: Task<Void, Never>?
    private var secureInputValidationTask: Task<Void, Never>?
    private var secureInputCleanupTask: Task<Void, Never>?
    private var secureInputState: SecureInputState = .inactive
    /// Fail visible until AppDelegate supplies the first permission snapshot.
    private var permissionState = PermissionState(hasAccessibility: false, hasScreenRecording: false)
    private var permissionPreviewMode: SBPreviewMode = .livePreviews
    private weak var secureInputStatusMenuItem: NSMenuItem?
    private weak var secureInputCleanupMenuItem: NSMenuItem?
    var onOpenPermissionSettings: ((PermissionKind) -> Void)? {
        didSet {
            rebuildStatusMenu()
            refreshSettingsRootView()
        }
    }

    init(secureInputMonitor: SecureInputMonitor = SecureInputMonitor()) {
        self.secureInputMonitor = secureInputMonitor
    }

    deinit {
        secureInputWatchdogTask?.cancel()
        secureInputValidationTask?.cancel()
        secureInputCleanupTask?.cancel()
    }

    func setup() {
        secureInputState = secureInputMonitor.currentState()
        installApplicationMainMenu()
        applyMenuBarVisibility(SwitchBladeSettings.shared.showMenuBarIcon)
        SwitchBladeSettings.shared.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] isVisible in
                self?.applyMenuBarVisibility(isVisible)
            }
            .store(in: &cancellables)
        SwitchBladeSettings.shared.$language
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] language in
                // @Published emits in willSet, before SwitchBladeSettings.didSet
                // mirrors the new selection to LocalizationState.
                LocalizationState.selection = language
                self?.refreshLocalizedUI()
            }
            .store(in: &cancellables)
        SwitchBladeSettings.shared.$previewMode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] previewMode in
                guard let self else { return }
                self.permissionPreviewMode = previewMode
                self.applyMenuBarVisibility(SwitchBladeSettings.shared.showMenuBarIcon)
                self.rebuildStatusMenu()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in
                MainActor.assumeIsolated {
                    SwitchBladeSettings.shared.refreshLaunchAtLoginStatus()
                }
            }
            .store(in: &cancellables)
        scheduleSecureInputRefresh(reason: "setup")
        startSecureInputWatchdog()
    }

    /// AppDelegate calls this after every permission refresh. Relevant missing
    /// permissions keep their recovery affordances reachable even when the user
    /// normally hides the status item.
    func updatePermissionState(
        _ state: PermissionState,
        previewMode: SBPreviewMode = SwitchBladeSettings.shared.previewMode
    ) {
        let didChange = state != permissionState || previewMode != permissionPreviewMode
        permissionState = state
        permissionPreviewMode = previewMode
        applyMenuBarVisibility(SwitchBladeSettings.shared.showMenuBarIcon)
        guard didChange else { return }
        rebuildStatusMenu()
        refreshSettingsRootView()
    }

    private func applyMenuBarVisibility(_ isVisible: Bool) {
        let shouldShow = Self.shouldShowStatusItem(
            userPreference: isVisible,
            secureInputActive: secureInputState.isActive,
            hasRelevantMissingPermissions: !permissionState
                .missingPermissions(for: permissionPreviewMode)
                .isEmpty
        )
        if shouldShow {
            if statusItem == nil {
                installStatusItem()
            }
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    static func shouldShowStatusItem(
        userPreference: Bool,
        secureInputActive: Bool,
        hasRelevantMissingPermissions: Bool
    ) -> Bool {
        userPreference || secureInputActive || hasRelevantMissingPermissions
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeMenuBarIcon()
        updateStatusButtonAccessibility(item.button)
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

        let missingPermissions = permissionState.missingPermissions(for: permissionPreviewMode)
        if !missingPermissions.isEmpty {
            let permissionHeader = NSMenuItem(
                title: L10n.tr(.menuPermissions),
                action: nil,
                keyEquivalent: ""
            )
            permissionHeader.isEnabled = false
            menu.addItem(permissionHeader)
            for permission in missingPermissions {
                let item = NSMenuItem(
                    title: String(format: L10n.tr(.menuOpenPermissionSettings), permission.title),
                    action: #selector(openPermissionSettings(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = permission.rawValue
                item.isEnabled = onOpenPermissionSettings != nil
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

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
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    private func rebuildStatusMenu() {
        guard let statusItem else { return }
        let menu = makeMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateSecureInputMenu()
    }

    @objc func openPermissionSettings(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let permission = PermissionKind(rawValue: rawValue) else { return }
        onOpenPermissionSettings?(permission)
    }

    private func updateStatusButtonAccessibility(_ button: NSStatusBarButton?) {
        guard let button else { return }
        button.toolTip = menuBarToolTip(for: secureInputState)
        button.setAccessibilityLabel(L10n.tr(.accessibilityStatusItemLabel))
        button.setAccessibilityHelp(L10n.tr(.accessibilityStatusItemHelp))
        button.setAccessibilityValue(secureInputStatusTitle(for: secureInputState))
    }

    func installApplicationMainMenu() {
        let topLevelTitles = Self.mainMenuTopLevelTitles(
            language: LocalizationState.effectiveLanguage
        )
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: topLevelTitles[0], action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: topLevelTitles[0])
        appMenu.addItem(targetedMenuItem(
            title: L10n.tr(.menuAbout),
            action: #selector(openAbout)
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(targetedMenuItem(
            title: L10n.tr(.menuSettings),
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: L10n.tr(.menuServices), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: L10n.tr(.menuServices))
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)

        appMenu.addItem(.separator())
        appMenu.addItem(systemMenuItem(
            title: L10n.tr(.menuHide),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        let hideOthers = systemMenuItem(
            title: L10n.tr(.menuHideOthers),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(systemMenuItem(
            title: L10n.tr(.menuShowAll),
            action: #selector(NSApplication.unhideAllApplications(_:))
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(systemMenuItem(
            title: L10n.tr(.menuQuit),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem(title: topLevelTitles[1], action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: topLevelTitles[1])
        // undo:/redo: are responder-chain actions without an AppKit protocol
        // declaration that Swift can reference through #selector.
        editMenu.addItem(responderMenuItem(title: L10n.tr(.menuUndo), action: NSSelectorFromString("undo:"), keyEquivalent: "z"))
        let redo = responderMenuItem(title: L10n.tr(.menuRedo), action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(responderMenuItem(title: L10n.tr(.menuCut), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(responderMenuItem(title: L10n.tr(.menuCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(responderMenuItem(title: L10n.tr(.menuPaste), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(responderMenuItem(title: L10n.tr(.menuSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem(title: topLevelTitles[2], action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: topLevelTitles[2])
        windowMenu.addItem(responderMenuItem(
            title: L10n.tr(.menuMinimize),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        windowMenu.addItem(responderMenuItem(title: L10n.tr(.menuZoom), action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(responderMenuItem(
            title: L10n.tr(.menuBringAllToFront),
            action: #selector(NSApplication.arrangeInFront(_:))
        ))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        let helpMenuItem = NSMenuItem(title: topLevelTitles[3], action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: topLevelTitles[3])
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.servicesMenu = servicesMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = mainMenu
    }

    static func mainMenuTopLevelTitles(language: AppLanguage) -> [String] {
        [
            "SwitchBlade",
            L10n.tr(.menuEdit, language: language),
            L10n.tr(.menuWindow, language: language),
            L10n.tr(.menuHelp, language: language)
        ]
    }

    private func targetedMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func systemMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = NSApp
        return item
    }

    private func responderMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    }

    func menuWillOpen(_ menu: NSMenu) {
        scheduleSecureInputRefresh(reason: "menu")
    }

    @objc func openSettings() {
        SwitchBladeSettings.shared.refreshLaunchAtLoginStatus()
        if settingsWindowController == nil {
            let view = makeSettingsView()
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.title = L10n.tr(.menuSettingsWindowTitle)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setAccessibilityRole(.window)
            window.setAccessibilitySubrole(.standardWindow)
            window.setAccessibilityLabel(L10n.tr(.menuSettingsWindowTitle))
            window.delegate = self
            window.contentMinSize = NSSize(width: 380, height: 420)
            host.view.layoutSubtreeIfNeeded()
            let fittingSize = host.view.fittingSize
            window.setContentSize(NSSize(
                width: max(420, fittingSize.width),
                height: max(620, fittingSize.height)
            ))
            centerWindowOnActiveScreen(window)
            settingsHostingController = host
            settingsWindowController = NSWindowController(window: window)
        } else if let window = settingsWindowController?.window {
            clampWindowToVisibleScreen(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsView() -> SettingsView {
        SettingsView(
            settings: SwitchBladeSettings.shared,
            permissionState: permissionState,
            onOpenPermissionSettings: { [weak self] permission in
                self?.onOpenPermissionSettings?(permission)
            }
        )
    }

    private func refreshSettingsRootView() {
        settingsHostingController?.rootView = makeSettingsView()
    }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: Self.aboutPanelOptions(bundleInfo: Bundle.main.infoDictionary ?? [:]))
    }

    @objc private func clearStuckSecureInput() {
        guard secureInputCleanupTask == nil else { return }
        let monitor = secureInputMonitor
        secureInputCleanupMenuItem?.isEnabled = false
        secureInputCleanupTask = Task { @MainActor [weak self] in
            let result = await monitor.clearStuckSecureInput()
            guard let self, !Task.isCancelled else { return }
            self.secureInputCleanupTask = nil
            self.secureInputState = result.after
            Logger.secureInput.notice(
                "Secure Input cleanup terminated \(result.terminated.count, privacy: .public) helper process(es); before=\(Self.logDescription(for: result.before), privacy: .public), after=\(Self.logDescription(for: result.after), privacy: .public)"
            )
            self.applyMenuBarVisibility(SwitchBladeSettings.shared.showMenuBarIcon)
            self.updateSecureInputMenu()
        }
    }

    func windowWillClose(_ notification: Notification) {
        closeAuxiliaryPanels()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === settingsWindowController?.window,
              let screen = sender.screen ?? activeScreen() else {
            return frameSize
        }
        let available = Self.availableFrame(inside: screen.visibleFrame)
        return NSSize(
            width: min(frameSize.width, available.width),
            height: min(frameSize.height, available.height)
        )
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindowController?.window else { return }
        clampWindowToVisibleScreen(window)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindowController?.window else { return }
        clampWindowToVisibleScreen(window)
    }

    private func closeAuxiliaryPanels() {
        let colorPanel = NSColorPanel.shared
        colorPanel.orderOut(nil)
        colorPanel.close()
    }

    private func activeScreen() -> NSScreen? {
        if let screen = settingsWindowController?.window?.screen {
            return screen
        }
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func clampWindowToVisibleScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? activeScreen() else { return }
        let available = Self.availableFrame(inside: screen.visibleFrame)
        window.minSize = NSSize(
            width: min(380, available.width),
            height: min(420, available.height)
        )
        let clamped = Self.clampedFrame(window.frame, inside: screen.visibleFrame)
        if clamped != window.frame {
            window.setFrame(clamped, display: true)
        }
    }

    private func centerWindowOnActiveScreen(_ window: NSWindow) {
        guard let screen = activeScreen() else {
            window.center()
            return
        }
        let visibleFrame = screen.visibleFrame
        let available = Self.availableFrame(inside: visibleFrame)
        window.minSize = NSSize(
            width: min(380, available.width),
            height: min(420, available.height)
        )
        let proposed = NSRect(
            x: visibleFrame.midX - window.frame.width / 2,
            y: visibleFrame.midY - window.frame.height / 2,
            width: window.frame.width,
            height: window.frame.height
        )
        window.setFrame(Self.clampedFrame(proposed, inside: visibleFrame), display: false)
    }

    static func availableFrame(inside visibleFrame: NSRect, margin: CGFloat = 12) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return visibleFrame }
        let horizontalMargin = min(max(0, margin), max(0, (visibleFrame.width - 1) / 2))
        let verticalMargin = min(max(0, margin), max(0, (visibleFrame.height - 1) / 2))
        return visibleFrame.insetBy(dx: horizontalMargin, dy: verticalMargin)
    }

    static func clampedFrame(
        _ proposedFrame: NSRect,
        inside visibleFrame: NSRect,
        margin: CGFloat = 12
    ) -> NSRect {
        let available = availableFrame(inside: visibleFrame, margin: margin)
        guard available.width > 0, available.height > 0 else { return visibleFrame }

        let width = min(max(proposedFrame.width, 1), available.width)
        let height = min(max(proposedFrame.height, 1), available.height)
        let maxX = available.maxX - width
        let maxY = available.maxY - height
        let x = min(max(proposedFrame.minX, available.minX), maxX)
        let y = min(max(proposedFrame.minY, available.minY), maxY)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func refreshLocalizedUI() {
        let aboutWasVisible = NSApp.windows.contains { window in
            window.isVisible
                && window !== settingsWindowController?.window
                && window.title.localizedCaseInsensitiveContains("SwitchBlade")
        }

        installApplicationMainMenu()
        settingsWindowController?.window?.title = L10n.tr(.menuSettingsWindowTitle)
        rebuildStatusMenu()

        if aboutWasVisible {
            NSApp.orderFrontStandardAboutPanel(
                options: Self.aboutPanelOptions(bundleInfo: Bundle.main.infoDictionary ?? [:])
            )
        }
    }

    private func startSecureInputWatchdog() {
        secureInputWatchdogTask?.cancel()
        secureInputWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.scheduleSecureInputRefresh(reason: "watchdog")
            }
        }
    }

    private func scheduleSecureInputRefresh(reason: String) {
        secureInputValidationTask?.cancel()
        secureInputValidationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let current = await self.secureInputMonitor.validatedCurrentState()
            guard !Task.isCancelled else { return }
            self.applySecureInputState(current, reason: reason)
            self.secureInputValidationTask = nil
        }
    }

    private func applySecureInputState(_ current: SecureInputState, reason: String) {
        let previous = secureInputState
        secureInputState = current

        if previous != current {
            Logger.secureInput.notice(
                "Secure Input state changed at \(reason, privacy: .public): \(Self.logDescription(for: current), privacy: .public)"
            )
            // Mirror the transition into performance.jsonl so a missed Cmd+Tab
            // can be correlated with Secure Input after the fact.
            PerformanceDiagnostics.record(
                "secure_input_state",
                fields: [
                    "active": .bool(current.isActive),
                    "pid": .int(Int(current.pid ?? 0)),
                    "executable": .string(current.process?.executableName ?? (current.isActive ? "unknown" : "")),
                    "reason": .string(reason)
                ]
            )
        }

        applyMenuBarVisibility(SwitchBladeSettings.shared.showMenuBarIcon)
        updateSecureInputMenu()
    }

    private func updateSecureInputMenu() {
        updateStatusButtonAccessibility(statusItem?.button)
        statusItem?.button?.contentTintColor = secureInputState.isActive ? .systemOrange : nil

        secureInputStatusMenuItem?.title = secureInputStatusTitle(for: secureInputState)

        let targets = secureInputMonitor.safeCleanupTargets(for: secureInputState)
        secureInputCleanupMenuItem?.isEnabled = secureInputCleanupTask == nil && !targets.isEmpty
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
            return "active pid=\(pid) cleanupSafe=\(SecureInputMonitor.isSafeCleanupTarget(process))"
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
