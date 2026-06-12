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
    private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var appTerminationRefreshTask: Task<Void, Never>?
    private var captureLifecycleTask: Task<Void, Never>?
    private var responsivenessActivity: NSObjectProtocol?
    private var lastPresentedMissingPermissions: [PermissionKind] = []
    private var isPresentingPermissionAlert = false
    /// Last observed Screen Recording grant. Used to detect the
    /// not-granted → granted transition mid-session so we can warm the SCKit
    /// cache on the same activation instead of waiting for the next Cmd+Tab
    /// (which would otherwise cold-start, possibly inheriting a 60 s
    /// failure cooldown if the launch-time refresh failed).
    private var lastKnownHadScreenRecording = false

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
        responsivenessActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep SwitchBlade global hotkey responsive while the system is awake"
        )

        if state.hasScreenRecording {
            Logger.capture.info("Starting SCKit cache warmup")
            Task { @MainActor [weak self] in
                await self?.warmCaptureCaches(context: "launch")
            }
            lastKnownHadScreenRecording = true
        } else {
            // Re-check after a short delay so TCC has settled from launch
            // prompts, without holding back already-authorized users.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self else { return }
                guard self.permissionService.currentState().hasScreenRecording else {
                    Logger.capture.notice("Skipping SCKit warmup — Screen Recording not granted")
                    return
                }
                Logger.capture.info("Starting delayed SCKit cache warmup")
                await self.warmCaptureCaches(context: "delayed launch")
                self.lastKnownHadScreenRecording = true
            }
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
                self?.store.requestCycle(forward: direction == .forward)
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
        hotkeyMonitor.onModifierDoubleTap = { [weak self] in
            MainActor.assumeIsolated {
                self?.store.switchToPreviousApplication()
            }
        }
        hotkeyMonitor.onModifierMouseSwitch = { [weak self] in
            MainActor.assumeIsolated {
                self?.store.handleModifierMouseSwitch()
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
        store.onOpenSettings = { [weak menuBar] in
            menuBar?.openSettings()
        }
        self.menuBarController = menuBar

        installLifecycleObservers()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        appTerminationRefreshTask?.cancel()
        captureLifecycleTask?.cancel()
        hotkeyMonitor?.stop()
        if let responsivenessActivity {
            ProcessInfo.processInfo.endActivity(responsivenessActivity)
            self.responsivenessActivity = nil
        }
        for (center, observer) in lifecycleObservers {
            center.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        // Only refresh state display — do NOT re-request permissions here,
        // that causes repeated OS prompts whenever the app comes to front.
        let state = permissionService.currentState()
        if state.hasScreenRecording && !lastKnownHadScreenRecording {
            // Screen Recording was just granted mid-session. Warm SCKit now so
            // the next Cmd+Tab is hot. The explicit refresh bypasses the 60 s
            // failure cooldown, so any earlier-failed refresh (e.g. denied at
            // launch) is healed too.
            Logger.capture.info("Screen Recording newly granted — warming SCKit cache")
            Task { @MainActor [weak self] in
                await self?.warmCaptureCaches(context: "screen recording granted")
            }
        }
        lastKnownHadScreenRecording = state.hasScreenRecording
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

    private func installLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        lifecycleObservers.append((
            workspaceCenter,
            workspaceCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                MainActor.assumeIsolated {
                    self?.handleApplicationTerminated(pid: pid)
                }
            }
        ))
        lifecycleObservers.append((
            workspaceCenter,
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleCaptureContentInvalidation(reason: "system will sleep", warmAfter: false)
                }
            }
        ))
        lifecycleObservers.append((
            workspaceCenter,
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.panelController?.invalidateLayoutCache(reason: "system did wake")
                    self?.handleCaptureContentInvalidation(reason: "system did wake", warmAfter: true)
                }
            }
        ))

        let defaultCenter = NotificationCenter.default
        lifecycleObservers.append((
            defaultCenter,
            defaultCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.panelController?.invalidateLayoutCache(reason: "screen parameters changed")
                    self?.handleCaptureContentInvalidation(reason: "screen parameters changed", warmAfter: true)
                }
            }
        ))
    }

    // Sleep drops the cache; wake and screen changes also re-warm because the
    // user's next action is typically Cmd+Tab and an empty cache there means a
    // visible cold-open delay. Sleep alone skips the warm — the system is on
    // its way down and warming would just be wasted work.
    private func handleCaptureContentInvalidation(reason: String, warmAfter: Bool) {
        Logger.capture.notice("Handling capture lifecycle event: \(reason, privacy: .public)")
        captureLifecycleTask?.cancel()
        captureLifecycleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.store.invalidateCaptureCache(reason: reason)
            guard !Task.isCancelled, warmAfter else { return }
            await self.warmCaptureCaches(context: reason)
        }
    }

    private func handleApplicationTerminated(pid: pid_t?) {
        guard pid != getpid() else { return }

        appTerminationRefreshTask?.cancel()
        appTerminationRefreshTask = Task { @MainActor [weak self] in
            // Coalesce rapid helper-process exits into one SCKit refresh.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }

            let reason = pid.map { "application terminated pid=\($0)" } ?? "application terminated"
            Logger.capture.notice("Handling capture lifecycle event: \(reason, privacy: .public)")
            await self.windowCatalog.invalidateAndRefreshContentCache(
                reason: reason,
                context: "application terminated"
            )
            self.store.scheduleOpenItemsCacheWarmup(context: "application terminated")
            self.store.schedulePreviewCacheWarmup(context: "application terminated")
        }
    }

    private func warmCaptureCaches(context: String) async {
        store.scheduleOpenItemsCacheWarmup(context: context)
        await windowCatalog.refreshContentCache(context: context)
        store.schedulePreviewCacheWarmup(context: context)
    }
}
