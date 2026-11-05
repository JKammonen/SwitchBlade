import AppKit
import Darwin
import Foundation
import Security
import os.log

/// Relaunches the running instance when its published bundle was replaced.
/// Only this process acts: the build script never kills or launches anything.
///
/// Locks are distinct. `instance.lock` is held for the whole life of a running
/// instance and is close-on-exec. `relaunch.lock` serializes relaunches: the
/// old instance takes it, and the helper inherits exactly that descriptor so
/// the lock outlives the old process until the new one acknowledges readiness.
/// The helper is `/bin/sh` with an inline script: it reads nothing from the
/// bundle and keeps working if the bundle is replaced again meanwhile.
/// Identity of this process captured at the very start of `main`: the mapped
/// executable (from the kernel, always correct) and the designated
/// requirement (from disk, which a publication racing process start can
/// already have replaced; then it is `nil`).
public enum LaunchIdentity {
    struct Snapshot: Sendable {
        let executable: FileStamp?
        let requirement: String?
        let bundleIdentifier: String?
    }

    private static let storage = LockedValue<Snapshot?>(nil)

    public static func capture() {
        guard storage.value == nil else { return }
        storage.value = Snapshot(
            executable: FileStamp.runningMainExecutable(),
            requirement: RelaunchCoordinator.designatedRequirementText(),
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static var current: Snapshot {
        if storage.value == nil { capture() }
        return storage.value!
    }
}

@MainActor
final class RelaunchCoordinator {
    private static let logger = Logger(subsystem: "com.jannekammonen.SwitchBlade", category: "relaunch")

    let paths: RelaunchPaths
    let bundleURL: URL
    let executableURL: URL
    private let launchStamp: BundleStamp
    /// Read at launch: once the bundle is replaced, this process can no
    /// longer derive its own static code from disk.
    private let launchRequirement: String?
    private let launchBundleIdentifier: String?
    private var lastRecordedOutcome: Outcome?
    private var monitorTimer: Timer?
    private var reportedPending = false
    private var relaunching = false

    /// Read before every attempt; relaunch only while nothing is in flight.
    var isIdle: () -> Bool = { true }
    /// Ranked live windows to hand over, most recent first.
    var rankedWindowsForHandoff: () -> [WindowItem] = { [] }

    init(paths: RelaunchPaths, bundleURL: URL, executableURL: URL) {
        self.paths = paths
        self.bundleURL = bundleURL
        self.executableURL = executableURL
        let identity = LaunchIdentity.current
        self.launchStamp = BundleStamp(
            executable: identity.executable ?? FileStamp.of(executableURL.path),
            infoPlist: FileStamp.of(bundleURL.appendingPathComponent("Contents/Info.plist").path)
        )
        self.launchRequirement = identity.requirement
        self.launchBundleIdentifier = identity.bundleIdentifier
    }

    /// Relaunch applies only to a signed app bundle, never to `swift run`.
    static var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.executableURL != nil
    }

    // MARK: - Singleton

    /// Must run before monitors, the event tap or hotkeys start. A relaunched
    /// instance waits briefly for the old process to release the lock.
    static func acquireInstanceLock(paths: RelaunchPaths, isRelaunch: Bool) -> FileLock? {
        let deadline = Date().addingTimeInterval(isRelaunch ? 5 : 0)
        repeat {
            if let lock = FileLock.acquire(at: paths.instanceLock) { return lock }
            if Date() >= deadline { break }
            usleep(100_000)
        } while true
        return nil
    }

    // MARK: - Detection

    func startMonitoring(interval: TimeInterval = 1) {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForReplacement() }
        }
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    func checkForReplacement() {
        guard !relaunching else { return }
        let current = BundleStamp.of(bundleURL: bundleURL, executableURL: executableURL)
        guard launchStamp.change(to: current) == .replaced else { return }
        guard isIdle() else {
            if !reportedPending {
                reportedPending = true
                PerformanceDiagnostics.record("relaunch_deferred", fields: ["reason": .string("not-idle")])
            }
            return
        }
        relaunch(reason: "bundle-replaced")
    }

    // MARK: - Relaunch

    enum Outcome: String, Sendable {
        case started
        case relaunchLockHeld = "relaunch-lock-held"
        case invalidSignature = "invalid-signature"
        case requirementUnavailable = "requirement-unavailable"
        case spawnFailed = "spawn-failed"
    }

    @discardableResult
    func relaunch(reason: String) -> Outcome {
        guard let relaunchLock = FileLock.acquire(at: paths.relaunchLock) else {
            return record(.relaunchLockHeld, reason: reason, requestID: nil)
        }
        // Fallback for a process whose bundle was replaced before `main`
        // could read its own requirement: accept the published bundle's own
        // requirement only for the same bundle identifier. Weaker than the
        // captured requirement, so it is recorded as such.
        var requirementSource = "launch"
        var resolvedRequirement = launchRequirement
        if resolvedRequirement == nil, let launchBundleIdentifier,
           let disk = Self.diskRequirement(of: bundleURL, bundleIdentifier: launchBundleIdentifier) {
            resolvedRequirement = disk
            requirementSource = "published-bundle-same-identifier"
        }
        guard let requirement = resolvedRequirement else {
            return record(.requirementUnavailable, reason: reason, requestID: nil)
        }
        if requirementSource != "launch" {
            PerformanceDiagnostics.record("relaunch_requirement_fallback", fields: ["source": .string(requirementSource)])
        }
        // First check: never leave the running instance for an invalid bundle.
        guard Self.bundle(bundleURL, satisfies: requirement) else {
            return record(.invalidSignature, reason: reason, requestID: nil)
        }
        let requestID = UUID().uuidString
        writeHandoff(requestID: requestID)
        try? FileManager.default.removeItem(at: paths.ack(for: requestID))

        let spawned = Self.spawnHelper(
            lockDescriptor: relaunchLock.descriptor, oldPID: getpid(), bundlePath: bundleURL.path,
            requestID: requestID, ackPath: paths.ack(for: requestID).path,
            requirement: requirement, logPath: paths.helperLog.path
        )
        guard spawned else {
            try? FileManager.default.removeItem(at: paths.handoff)
            return record(.spawnFailed, reason: reason, requestID: requestID)
        }
        relaunching = true
        stopMonitoring()
        _ = record(.started, reason: reason, requestID: requestID)
        // The helper holds its own copy of the relaunch-lock descriptor.
        withExtendedLifetime(relaunchLock) {}
        PerformanceDiagnostics.waitForPendingWrites()
        NSApp.terminate(nil)
        return .started
    }

    private func record(_ outcome: Outcome, reason: String, requestID: String?) -> Outcome {
        // A blocked attempt repeats every check; record each outcome once.
        guard outcome == .started || outcome != lastRecordedOutcome else { return outcome }
        lastRecordedOutcome = outcome
        var fields: [String: PerformanceMetricValue] = [
            "outcome": .string(outcome.rawValue), "reason": .string(reason)
        ]
        if let requestID { fields["request_id"] = .string(requestID) }
        PerformanceDiagnostics.record("relaunch_request", fields: fields)
        Self.logger.notice("relaunch \(outcome.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
        return outcome
    }

    private func writeHandoff(requestID: String) {
        guard let boot = ProcessIdentity.bootSessionUUID() else { return }
        let handoff = RelaunchHandoff.make(
            requestID: requestID, bootSessionUUID: boot, now: Date(),
            rankedItems: rankedWindowsForHandoff(), startTime: ProcessIdentity.startTime(of:)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard var data = try? encoder.encode(handoff) else { return }
        if Self.consumeFault(paths.corruptHandoffFault) {
            data = Data("corrupt".utf8)
            PerformanceDiagnostics.record("relaunch_fault_injected", fields: ["fault": .string("corrupt-handoff")])
        }
        try? paths.writeAtomically(data, to: paths.handoff)
    }

    // MARK: - Relaunched side

    /// Called once launch setup finished (monitors, tap, hotkeys running).
    /// Imports the handoff, then acknowledges readiness for the helper.
    static func completeRelaunch(
        requestID: String, paths: RelaunchPaths, apply: ([RelaunchHandoff.Entry]?, RelaunchHandoff.Rejection?) -> Int
    ) {
        var rejection: RelaunchHandoff.Rejection?
        var entries: [RelaunchHandoff.Entry]?
        if let data = paths.consumeHandoff() {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let handoff = try? decoder.decode(RelaunchHandoff.self, from: data) {
                rejection = handoff.validate(requestID: requestID, bootSessionUUID: ProcessIdentity.bootSessionUUID(),
                                             now: Date())
                if rejection == nil { entries = handoff.entries }
            } else {
                rejection = .unreadable
            }
        } else {
            // Already consumed (by an attempt that crashed before its
            // acknowledgement) or never written: ranks start from bundles.
            rejection = .missing
        }
        let restored = apply(entries, rejection)
        if consumeFault(paths.crashBeforeAckFault) {
            PerformanceDiagnostics.record("relaunch_fault_injected", fields: ["fault": .string("crash-before-ack")])
            PerformanceDiagnostics.waitForPendingWrites()
            abort()
        }
        try? paths.writeAtomically(Data("\(requestID) \(getpid())\n".utf8), to: paths.ack(for: requestID))
        PerformanceDiagnostics.record("relaunch_completed", fields: [
            "request_id": .string(requestID),
            "handoff_rejection": .string(rejection?.rawValue ?? "none"),
            "handoff_entries": .int(entries?.count ?? 0),
            "restored_ranks": .int(restored)
        ])
    }

    /// Acceptance-run fault injection. A fault file holds a remaining count;
    /// each use decrements it and the file is removed at zero. Absent in
    /// normal use, so these paths never trigger on their own.
    static func consumeFault(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let remaining = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), remaining > 0 else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        if remaining <= 1 {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? Data("\(remaining - 1)".utf8).write(to: url)
        }
        return true
    }

    // MARK: - Code signature

    nonisolated static func designatedRequirementText() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// Designated requirement of a validly signed bundle, only when its
    /// identifier matches.
    nonisolated static func diskRequirement(of url: URL, bundleIdentifier: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              dictionary[kSecCodeInfoIdentifier as String] as? String == bundleIdentifier else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            return nil
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// The bundle at the path must be validly signed by our own designated
    /// requirement (same identifier and signing certificate).
    nonisolated static func bundle(_ url: URL, satisfies text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }

    // MARK: - Helper

    /// Waits for the old process, re-verifies the bundle, launches it with the
    /// request ID and waits for the readiness acknowledgement. One retry.
    /// Exits (releasing the inherited relaunch lock on fd 3) when done.
    static let helperScript = #"""
    old="$1"; bundle="$2"; req="$3"; ack="$4"; requirement="$5"
    log() { printf '%s %s %s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$req" "$1"; }
    n=0
    while /bin/kill -0 "$old" 2>/dev/null; do
      n=$((n+1)); if [ "$n" -gt 100 ]; then log "failed old-process-still-running"; exit 1; fi
      /bin/sleep 0.1
    done
    attempt=1
    while [ "$attempt" -le 2 ]; do
      v=0
      until /usr/bin/codesign --verify --strict -R "=$requirement" "$bundle" 2>/dev/null; do
        v=$((v+1)); if [ "$v" -gt 20 ]; then log "failed invalid-signature attempt=$attempt"; exit 1; fi
        /bin/sleep 0.5
      done
      /bin/rm -f "$ack"
      /usr/bin/open "$bundle" --args --switchblade-relaunch-request "$req"
      w=0
      while [ ! -f "$ack" ]; do
        w=$((w+1)); if [ "$w" -gt 150 ]; then break; fi
        /bin/sleep 0.1
      done
      if [ -f "$ack" ] && /usr/bin/grep -q "^$req " "$ack"; then
        log "ok attempt=$attempt"; /bin/rm -f "$ack"; exit 0
      fi
      log "no-ack attempt=$attempt"
      # Another instance of this bundle won the instance lock (for example
      # an explicit launch during the handover): one instance runs, so stop.
      if /usr/bin/pgrep -f "^$bundle/Contents/MacOS/" >/dev/null 2>&1; then
        log "superseded running-instance"; exit 0
      fi
      attempt=$((attempt+1))
    done
    log "failed no-ack"
    exit 1
    """#

    static func spawnHelper(
        lockDescriptor: Int32, oldPID: pid_t, bundlePath: String, requestID: String,
        ackPath: String, requirement: String, logPath: String
    ) -> Bool {
        spawnDetachedShell(script: helperScript, arguments: [String(oldPID), bundlePath, requestID, ackPath, requirement],
                           inheritedDescriptor: lockDescriptor, logPath: logPath) != nil
    }

    /// `/bin/sh -c script` in its own session. Inherits only stdin (/dev/null),
    /// stdout/stderr (append to `logPath`) and `inheritedDescriptor` as fd 3.
    static func spawnDetachedShell(
        script: String, arguments: [String], inheritedDescriptor: Int32, logPath: String
    ) -> pid_t? {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        // New session: survives our exit. CLOEXEC_DEFAULT: only the descriptors
        // set up below are inherited, never instance.lock or anything else.
        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0 else { return nil }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_adddup2(&actions, inheritedDescriptor, 3)

        let arguments = ["/bin/sh", "-c", script, "switchblade-relaunch"] + arguments
        var cArguments = arguments.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", &actions, &attributes, &cArguments, environ)
        return status == 0 ? pid : nil
    }
}
