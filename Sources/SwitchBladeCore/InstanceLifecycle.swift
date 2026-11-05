import AppKit
import Darwin
import Foundation
import os.log

/// Executable identity captured first in `main`, from the kernel's mapped
/// image (never the path), so the replacement check compares against the code
/// this process really runs.
public enum LaunchIdentity {
    private static let storage = LockedValue<FileStamp?>(nil)
    private static let captured = LockedValue(false)

    public static func capture() {
        guard !captured.value else { return }
        storage.value = FileStamp.runningMainExecutable()
        captured.value = true
    }

    static var executable: FileStamp? {
        if !captured.value { capture() }
        return storage.value
    }
}

/// The running instance's side of the lifecycle. `build-app.sh` owns
/// publication: it stops this instance (SIGTERM), swaps the bundle, launches
/// the new one and waits for its ready marker. This class only:
/// - holds the single-instance lock,
/// - turns SIGTERM into a graceful quit once idle, writing the rank handoff,
/// - restores the handoff and writes the ready marker after launch setup,
/// - warns when the bundle was replaced some other way (the AX permission
///   failure then applies until a restart, which the menu offers).
@MainActor
final class InstanceLifecycle {
    private static let logger = Logger(subsystem: "com.jannekammonen.SwitchBlade", category: "lifecycle")
    /// Longest wait for an idle moment before a requested quit proceeds.
    static let maximumQuitDeferral: TimeInterval = 3

    let paths: LifecyclePaths
    let bundleURL: URL
    let executableURL: URL
    private let launchExecutable: FileStamp?
    private var monitorTimer: Timer?
    private var signalSource: DispatchSourceSignal?
    private var quitRequestedAt: Date?
    private(set) var replacementDetected = false

    /// Read while a quit is pending; quit proceeds once idle or after the cap.
    var isIdle: () -> Bool = { true }
    /// Concrete window ranks, most recent first, for the handoff.
    var ranksForHandoff: () -> [RelaunchHandoff.Rank] = { [] }
    /// Called once when the published bundle no longer matches this process.
    var onReplacementDetected: () -> Void = {}

    init(paths: LifecyclePaths, bundleURL: URL, executableURL: URL) {
        self.paths = paths
        self.bundleURL = bundleURL
        self.executableURL = executableURL
        self.launchExecutable = LaunchIdentity.executable ?? FileStamp.of(executableURL.path)
    }

    /// Lifecycle handling applies only to a signed app bundle, never `swift run`.
    static var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.executableURL != nil
    }

    // MARK: - Single instance

    enum InstanceLock {
        case acquired([FileLock])
        case anotherInstanceRuns
        /// Neither lock file could be opened: run unlocked rather than not at
        /// all, and record it.
        case unavailable(Int32)
    }

    /// Must run before monitors, the event tap or hotkeys start. Both the
    /// primary and the fallback lock are taken when they can be opened, so an
    /// instance that had to use the fallback still excludes a later one that
    /// can open the primary. Only a held lock means another instance runs.
    static func acquireInstanceLock(paths: LifecyclePaths) -> InstanceLock {
        let primary = FileLock.attempt(at: paths.instanceLock)
        if case .held = primary { return .anotherInstanceRuns }
        let fallback = FileLock.attempt(at: paths.fallbackInstanceLock)
        if case .held = fallback { return .anotherInstanceRuns }
        var held: [FileLock] = []
        if case .acquired(let lock) = primary { held.append(lock) }
        if case .acquired(let lock) = fallback { held.append(lock) }
        if held.isEmpty {
            if case .unavailable(let error) = fallback { return .unavailable(error) }
            return .unavailable(0)
        }
        return .acquired(held)
    }

    // MARK: - Ready marker

    /// Written once launch setup finished. `build-app.sh` accepts a relaunch
    /// only when this names a live process whose mapped executable is the
    /// published file (same inode), written after it launched the bundle.
    @discardableResult
    func writeReadyMarker(now: Date = Date()) -> Bool {
        guard let inode = launchExecutable?.inode else { return false }
        let text = "\(getpid()) \(inode) \(Int(now.timeIntervalSince1970))\n"
        return (try? paths.writeAtomically(Data(text.utf8), to: paths.readyMarker)) != nil
    }

    // MARK: - Graceful quit on SIGTERM

    func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.requestQuit(reason: "sigterm") }
        }
        source.resume()
        signalSource = source
    }

    /// Defers to an idle moment (no open switcher, no window action in
    /// flight) for at most `maximumQuitDeferral`, then quits gracefully so
    /// `applicationWillTerminate` writes the handoff.
    func requestQuit(reason: String) {
        guard quitRequestedAt == nil else { return }
        quitRequestedAt = Date()
        PerformanceDiagnostics.record("lifecycle_quit_requested", fields: ["reason": .string(reason)])
        pollQuit()
    }

    static func shouldQuitNow(isIdle: Bool, waited: TimeInterval) -> Bool {
        isIdle || waited >= maximumQuitDeferral
    }

    private func pollQuit() {
        guard let requestedAt = quitRequestedAt else { return }
        let idle = isIdle()
        let waited = Date().timeIntervalSince(requestedAt)
        guard Self.shouldQuitNow(isIdle: idle, waited: waited) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.pollQuit() }
            }
            return
        }
        PerformanceDiagnostics.record("lifecycle_quit", fields: [
            "waited_ms": .double(waited * 1000), "idle": .bool(idle)
        ])
        PerformanceDiagnostics.waitForPendingWrites()
        NSApp.terminate(nil)
    }

    // MARK: - Rank handoff

    /// Called from `applicationWillTerminate`.
    func writeHandoff() {
        guard let boot = ProcessIdentity.bootSessionUUID() else { return }
        let handoff = RelaunchHandoff.make(
            bootSessionUUID: boot, now: Date(), ranks: ranksForHandoff(),
            windowOwners: RelaunchHandoff.currentWindowOwners(), startTime: ProcessIdentity.startTime(of:)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(handoff) else { return }
        let written = (try? paths.writeAtomically(data, to: paths.handoff)) != nil
        PerformanceDiagnostics.record("lifecycle_handoff_written", fields: [
            "entries": .int(handoff.entries.count), "written": .bool(written)
        ])
        PerformanceDiagnostics.waitForPendingWrites()
    }

    /// Reads and removes the handoff (one launch consumes it) and returns the
    /// entries whose windows and owner processes are unchanged.
    static func takeHandoff(
        paths: LifecyclePaths, now: Date = Date(),
        windowOwners: [CGWindowID: pid_t] = RelaunchHandoff.currentWindowOwners(),
        startTime: (pid_t) -> ProcessIdentity.StartTime? = ProcessIdentity.startTime(of:),
        bootSessionUUID: String? = ProcessIdentity.bootSessionUUID()
    ) -> (entries: [RelaunchHandoff.Entry], rejection: RelaunchHandoff.Rejection?) {
        guard let data = try? Data(contentsOf: paths.handoff) else { return ([], .missing) }
        try? FileManager.default.removeItem(at: paths.handoff)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let handoff = try? decoder.decode(RelaunchHandoff.self, from: data) else { return ([], .unreadable) }
        if let rejection = handoff.validate(bootSessionUUID: bootSessionUUID, now: now) { return ([], rejection) }
        return (RelaunchHandoff.restorableEntries(handoff.entries, windowOwners: windowOwners, startTime: startTime), nil)
    }

    // MARK: - Replacement outside build-app.sh

    func startMonitoring(interval: TimeInterval = 2) {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForReplacement() }
        }
    }

    func checkForReplacement() {
        guard !replacementDetected, let launchExecutable,
              let current = FileStamp.of(executableURL.path), current != launchExecutable else { return }
        replacementDetected = true
        monitorTimer?.invalidate()
        PerformanceDiagnostics.record("bundle_replaced_while_running", fields: [:])
        Self.logger.notice("bundle replaced under the running instance; restart required")
        onReplacementDetected()
    }

    /// User-initiated from the menu: start the published bundle once this
    /// process has exited, then quit gracefully (writing the handoff).
    func restartFromMenu() {
        let script = "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$1\""
        _ = Self.spawnDetachedShell(script: script, arguments: [String(getpid()), bundleURL.path])
        requestQuit(reason: "menu-restart")
    }

    /// `/bin/sh -c script` in its own session with only /dev/null as stdio:
    /// it inherits no descriptor (in particular not the instance lock).
    static func spawnDetachedShell(script: String, arguments: [String]) -> pid_t? {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        // Default signal dispositions: this process ignores SIGTERM (handled by
        // a dispatch source), which a child would otherwise inherit.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF)
        guard posix_spawnattr_setflags(&attributes, flags) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let argv = ["/bin/sh", "-c", script] + arguments
        var cArguments = argv.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, "/bin/sh", &actions, &attributes, &cArguments, environ) == 0 ? pid : nil
    }
}
