import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permissionService = PermissionService()
    private lazy var windowCatalog = WindowCatalog(permissionService: permissionService)
    private let windowActivator = WindowActivator()
    private lazy var store = SwitcherStore(
        catalog: windowCatalog,
        activator: windowActivator,
        permissionService: permissionService
    )
    private var panelController: SwitcherPanelController?
    private var hotkeyMonitor: HotkeyMonitor?
    private var menuBarController: MenuBarController?
    private var lastPresentedMissingPermissions: [PermissionKind] = []
    private var isPresentingPermissionAlert = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu-bar-only agent — no Dock icon, and ensures our own
        // windows are excluded from the switcher (activationPolicy != .regular).
        NSApp.setActivationPolicy(.accessory)

        permissionService.requestIfNeeded()

        // Warm SC cache after a short delay so TCC has settled from the
        // accessibility prompt above. Only fires when SR is already granted.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.permissionService.currentState().hasScreenRecording else { return }
            self.windowCatalog.startBackgroundRefresh()
        }

        let panelController = SwitcherPanelController(store: store)
        store.refreshPermissionState()
        presentPermissionGuidanceIfNeeded()
        store.onShow = { [weak panelController, weak store] in
            panelController?.show(itemCount: store?.items.count ?? 0)
        }
        store.onHide = { [weak panelController] in
            panelController?.hide()
        }
        self.panelController = panelController

        let hotkeyMonitor = HotkeyMonitor()
        hotkeyMonitor.onHotkey = { [weak self] direction in
            MainActor.assumeIsolated {
                self?.store.cycle(forward: direction == .forward)
            }
        }
        hotkeyMonitor.shouldTrackModifierRelease = { [weak self] in
            MainActor.assumeIsolated {
                // Also true while previews are loading (isSwitching) so a
                // quick Cmd+Tab+release works even before isVisible is set.
                self?.store.isVisible == true || self?.store.isSwitching == true
            }
        }
        hotkeyMonitor.onCommandReleased = { [weak self] in
            MainActor.assumeIsolated {
                self?.store.commitSelection()
            }
        }
        hotkeyMonitor.onLocalKeyDown = { [weak self] event in
            MainActor.assumeIsolated {
                self?.store.handleKeyDown(event) ?? false
            }
        }
        hotkeyMonitor.start()
        self.hotkeyMonitor = hotkeyMonitor

        let menuBar = MenuBarController()
        menuBar.setup()
        self.menuBarController = menuBar
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Only refresh state display — do NOT re-request permissions here,
        // that causes repeated OS prompts whenever the app comes to front.
        store.refreshPermissionState()
        hotkeyMonitor?.start()
    }

    private func refreshPermissionsAndHotkeyCapture() {
        store.refreshPermissionState()
        presentPermissionGuidanceIfNeeded()
        hotkeyMonitor?.start()
    }

    private func presentPermissionGuidanceIfNeeded() {
        let state = permissionService.currentState()
        let missingPermissions = state.missingPermissions

        guard !missingPermissions.isEmpty else {
            lastPresentedMissingPermissions = []
            return
        }

        if missingPermissions == [.screenRecording] {
            return
        }

        guard !isPresentingPermissionAlert,
              missingPermissions != lastPresentedMissingPermissions,
              let permission = state.primaryMissingPermission else {
            return
        }

        lastPresentedMissingPermissions = missingPermissions
        isPresentingPermissionAlert = true

        defer {
            isPresentingPermissionAlert = false
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "SwitchBlade tarvitsee luvan: \(permission.title)"
        alert.informativeText = guidanceText(for: state, primaryPermission: permission)
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(permission.settingsURL)
        }
    }

    private func guidanceText(for state: PermissionState, primaryPermission: PermissionKind) -> String {
        let missingTitles = state.missingPermissions.map(\.title).joined(separator: ", ")
        return "SwitchBlade tarvitsee luvan toimiakseen. Puuttuvat luvat: \(missingTitles). Avaa oikea System Settings -sivu ja laita SwitchBlade päälle."
    }
}