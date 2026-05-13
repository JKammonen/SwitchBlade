import AppKit
import os.log

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    private let permissionService = PermissionService()
    private let windowCatalog = WindowCatalog()
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

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.app.info("SwitchBlade launching (pid: \(getpid(), privacy: .public))")
        // Run as a menu-bar-only agent — no Dock icon, and ensures our own
        // windows are excluded from the switcher (activationPolicy != .regular).
        NSApp.setActivationPolicy(.accessory)

        permissionService.requestIfNeeded()
        let state = permissionService.currentState()
        Logger.permissions.info(
            "Permissions on launch: ax=\(state.hasAccessibility, privacy: .public), sr=\(state.hasScreenRecording, privacy: .public)"
        )

        // Warm SC cache after a short delay so TCC has settled from the
        // accessibility prompt above. Only fires when SR is already granted.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            guard self.permissionService.currentState().hasScreenRecording else {
                Logger.capture.notice("Skipping SCKit warmup — Screen Recording not granted")
                return
            }
            Logger.capture.info("Starting SCKit cache warmup")
            self.windowCatalog.startBackgroundRefresh()
        }

        let panelController = SwitcherPanelController(store: store)
        // Click anywhere outside the rounded card area dismisses the switcher.
        panelController.onClickOutside = { [weak store] in
            store?.cancel()
        }
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

    public func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        // Only refresh state display — do NOT re-request permissions here,
        // that causes repeated OS prompts whenever the app comes to front.
        store.refreshPermissionState()
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
        alert.messageText = L10n.tr(.alertPermissionTitle, permission.title)
        alert.informativeText = guidanceText(for: state, primaryPermission: permission)
        alert.addButton(withTitle: L10n.tr(.alertOpenSettings))
        alert.addButton(withTitle: L10n.tr(.alertLater))

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(permission.settingsURL)
        }
    }

    private func guidanceText(for state: PermissionState, primaryPermission: PermissionKind) -> String {
        let missingTitles = state.missingPermissions.map(\.title).joined(separator: ", ")
        return L10n.tr(.alertPermissionBody, missingTitles)
    }
}