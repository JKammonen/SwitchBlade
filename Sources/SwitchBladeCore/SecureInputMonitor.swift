import AppKit
import Darwin
import Foundation
import IOKit
import Security
import os.log

struct SecureInputProcess: Equatable {
    let pid: pid_t
    let displayName: String
    let bundleIdentifier: String?
    let executablePath: String?
    let startTimeMicroseconds: UInt64?
    let isTrustedAppleSystemExecutable: Bool

    var executableName: String {
        executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? displayName
    }

    func withTrustedAppleSystemExecutable(_ isTrusted: Bool) -> SecureInputProcess {
        SecureInputProcess(
            pid: pid,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            executablePath: executablePath,
            startTimeMicroseconds: startTimeMicroseconds,
            isTrustedAppleSystemExecutable: isTrusted
        )
    }

    func withValidatedSystemIdentity(
        bundleIdentifier: String,
        isTrusted: Bool
    ) -> SecureInputProcess {
        SecureInputProcess(
            pid: pid,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            executablePath: executablePath,
            startTimeMicroseconds: startTimeMicroseconds,
            isTrustedAppleSystemExecutable: isTrusted
        )
    }
}

struct SecureInputState: Equatable {
    let pid: pid_t?
    let process: SecureInputProcess?

    static let inactive = SecureInputState(pid: nil, process: nil)

    var isActive: Bool { pid != nil }
    var isStale: Bool { pid != nil && process == nil }
}

struct SecureInputCleanupResult: Equatable {
    let before: SecureInputState
    let terminated: [SecureInputProcess]
    let after: SecureInputState
}

@MainActor
final class SecureInputMonitor {
    typealias PIDReader = () -> pid_t?
    typealias ProcessResolver = (pid_t) -> SecureInputProcess?
    typealias Terminator = (pid_t) -> Bool
    typealias TrustValidator = @Sendable (String) -> Bool

    private let readSecureInputPID: PIDReader
    private let resolveProcess: ProcessResolver
    private let terminateProcess: Terminator
    private let validateExecutableTrust: TrustValidator
    private let recheckDelayNanoseconds: UInt64
    private let executableTrustCache = LockedValue<[String: Bool]>([:])

    init(
        readSecureInputPID: @escaping PIDReader = SecureInputMonitor.readSecureInputPIDFromIORegistry,
        resolveProcess: @escaping ProcessResolver = SecureInputMonitor.processInfo,
        terminateProcess: @escaping Terminator = SecureInputMonitor.terminate,
        validateExecutableTrust: @escaping TrustValidator = SecureInputMonitor.isTrustedAppleSystemExecutable,
        recheckDelayNanoseconds: UInt64 = 400_000_000
    ) {
        self.readSecureInputPID = readSecureInputPID
        self.resolveProcess = resolveProcess
        self.terminateProcess = terminateProcess
        self.validateExecutableTrust = validateExecutableTrust
        self.recheckDelayNanoseconds = recheckDelayNanoseconds
    }

    func currentState() -> SecureInputState {
        guard let pid = readSecureInputPID() else {
            return .inactive
        }
        guard let process = resolveProcess(pid) else {
            return SecureInputState(pid: pid, process: nil)
        }
        guard !process.isTrustedAppleSystemExecutable,
              let path = process.executablePath,
              let cachedTrust = executableTrustCache.withValue({ $0[path] }) else {
            return SecureInputState(pid: pid, process: process)
        }
        let cachedProcess: SecureInputProcess
        if cachedTrust, let identity = Self.cleanupIdentityCandidate(for: process) {
            cachedProcess = process.withValidatedSystemIdentity(
                bundleIdentifier: identity.bundleIdentifier,
                isTrusted: true
            )
        } else {
            cachedProcess = process.withTrustedAppleSystemExecutable(false)
        }
        return SecureInputState(
            pid: pid,
            process: cachedProcess
        )
    }

    /// Performs owner/signature validation away from MainActor and caches the
    /// immutable system-executable result by canonical process path. The cheap
    /// synchronous state read above can then be used by menu rendering without
    /// filesystem or Security.framework work on the UI thread.
    func validatedCurrentState() async -> SecureInputState {
        let state = currentState()
        guard let process = state.process,
              !process.isTrustedAppleSystemExecutable,
              let identity = Self.cleanupIdentityCandidate(for: process),
              let path = process.executablePath else {
            return state
        }

        if let cachedTrust = executableTrustCache.withValue({ $0[path] }) {
            let cachedProcess = cachedTrust
                ? process.withValidatedSystemIdentity(
                    bundleIdentifier: identity.bundleIdentifier,
                    isTrusted: true
                )
                : process.withTrustedAppleSystemExecutable(false)
            return SecureInputState(pid: state.pid, process: cachedProcess)
        }

        let validator = validateExecutableTrust
        let isTrusted = await Task.detached(priority: .utility) {
            validator(path)
        }.value
        executableTrustCache.withValue { $0[path] = isTrusted }
        let validatedProcess = isTrusted
            ? process.withValidatedSystemIdentity(
                bundleIdentifier: identity.bundleIdentifier,
                isTrusted: true
            )
            : process.withTrustedAppleSystemExecutable(false)
        return SecureInputState(pid: state.pid, process: validatedProcess)
    }

    func safeCleanupTargets(for state: SecureInputState) -> [SecureInputProcess] {
        guard let secureInputPID = state.pid,
              let process = state.process,
              process.pid == secureInputPID,
              Self.isSafeCleanupTarget(process) else {
            return []
        }
        return [process]
    }

    func clearStuckSecureInput() async -> SecureInputCleanupResult {
        let before = await validatedCurrentState()
        let targets = safeCleanupTargets(for: before)
        var terminated: [SecureInputProcess] = []
        for target in targets {
            // Resolve again immediately before signaling. The Secure Input PID
            // may have exited and been reused since the first snapshot.
            guard let current = resolveProcess(target.pid),
                  let currentIdentity = Self.cleanupIdentityCandidate(for: current) else {
                continue
            }
            let validatedCurrent = current.withValidatedSystemIdentity(
                bundleIdentifier: currentIdentity.bundleIdentifier,
                isTrusted: target.isTrustedAppleSystemExecutable
            )
            guard Self.hasSameStableIdentity(target, validatedCurrent),
                  Self.isSafeCleanupTarget(validatedCurrent),
                  readSecureInputPID() == current.pid,
                  terminateProcess(current.pid) else {
                continue
            }
            terminated.append(validatedCurrent)
        }

        if !terminated.isEmpty, recheckDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: recheckDelayNanoseconds)
        }

        let after = currentState()
        return SecureInputCleanupResult(before: before, terminated: terminated, after: after)
    }

    nonisolated static func secureInputPID(from consoleUsers: Any?) -> pid_t? {
        guard let users = consoleUsers as? [Any] else { return nil }

        for case let user as [String: Any] in users {
            if let pid = pidValue(user["kCGSSessionSecureInputPID"]) {
                return pid
            }
        }
        return nil
    }

    static func isSafeCleanupTarget(_ process: SecureInputProcess) -> Bool {
        guard let identity = cleanupIdentityCandidate(for: process) else { return false }
        return process.bundleIdentifier == identity.bundleIdentifier
            && process.isTrustedAppleSystemExecutable
    }

    private struct AllowedCleanupIdentity: Sendable {
        let executableName: String
        let bundleIdentifier: String
    }

    private static func cleanupIdentityCandidate(
        for process: SecureInputProcess
    ) -> AllowedCleanupIdentity? {
        guard let path = process.executablePath,
              let identity = safeCleanupIdentitiesByPath[path],
              process.executableName == identity.executableName,
              process.bundleIdentifier == nil || process.bundleIdentifier == identity.bundleIdentifier else {
            return nil
        }
        return identity
    }

    private static func hasSameStableIdentity(
        _ expected: SecureInputProcess,
        _ current: SecureInputProcess
    ) -> Bool {
        guard let expectedStart = expected.startTimeMicroseconds,
              let currentStart = current.startTimeMicroseconds else {
            return false
        }
        return expected.pid == current.pid
            && expected.bundleIdentifier == current.bundleIdentifier
            && expected.executablePath == current.executablePath
            && expectedStart == currentStart
    }

    nonisolated private static let safeCleanupIdentitiesByPath: [String: AllowedCleanupIdentity] = [
        "/System/Library/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIService.xpc/Contents/MacOS/QuickLookUIService": .init(
            executableName: "QuickLookUIService",
            bundleIdentifier: "com.apple.quicklook.QuickLookUIService"
        ),
        "/System/Library/Frameworks/QuickLookThumbnailing.framework/Support/com.apple.quicklook.ThumbnailsAgent": .init(
            executableName: "com.apple.quicklook.ThumbnailsAgent",
            bundleIdentifier: "com.apple.quicklook.ThumbnailsAgent"
        ),
        "/System/Library/CoreServices/TextInputMenuAgent.app/Contents/MacOS/TextInputMenuAgent": .init(
            executableName: "TextInputMenuAgent",
            bundleIdentifier: "com.apple.TextInputMenuAgent"
        ),
        "/System/Library/CoreServices/TextInputSwitcher.app/Contents/MacOS/TextInputSwitcher": .init(
            executableName: "TextInputSwitcher",
            bundleIdentifier: "com.apple.TextInputSwitcher"
        ),
        "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService": .init(
            executableName: "CursorUIViewService",
            bundleIdentifier: "com.apple.TextInputUI.xpc.CursorUIViewService"
        )
    ]

    nonisolated static func readSecureInputPIDFromIORegistry() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        guard let consoleUsers = IORegistryEntryCreateCFProperty(
            root,
            "IOConsoleUsers" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }

        return secureInputPID(from: consoleUsers)
    }

    nonisolated private static func pidValue(_ value: Any?) -> pid_t? {
        switch value {
        case let number as NSNumber:
            let pid = number.int32Value
            return pid > 0 ? pid : nil
        case let int as Int:
            return int > 0 ? pid_t(int) : nil
        case let int32 as Int32:
            return int32 > 0 ? pid_t(int32) : nil
        case let string as String:
            guard let pid = Int32(string), pid > 0 else { return nil }
            return pid
        default:
            return nil
        }
    }

    nonisolated static func processInfo(pid: pid_t) -> SecureInputProcess? {
        guard pid > 0 else { return nil }
        if Darwin.kill(pid, 0) == -1 && errno == ESRCH {
            return nil
        }

        let runningApp = NSRunningApplication(processIdentifier: pid)
        let rawExecutablePath = runningApp?.executableURL?.path ?? executablePath(pid: pid)
        let executablePath = rawExecutablePath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        let displayName = runningApp?.localizedName
            ?? executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "pid \(pid)"

        return SecureInputProcess(
            pid: pid,
            displayName: displayName,
            bundleIdentifier: runningApp?.bundleIdentifier,
            executablePath: executablePath,
            startTimeMicroseconds: processStartTimeMicroseconds(pid: pid),
            isTrustedAppleSystemExecutable: false
        )
    }

    nonisolated private static func processStartTimeMicroseconds(pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard actualSize == Int32(expectedSize) else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    nonisolated private static func isTrustedAppleSystemExecutable(at path: String) -> Bool {
        let canonicalPath = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard let expectedIdentity = safeCleanupIdentitiesByPath[canonicalPath] else {
            return false
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: canonicalPath),
              let ownerID = attributes[.ownerAccountID] as? NSNumber,
              ownerID.uint32Value == 0 else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: canonicalPath) as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
            let staticCode else {
            return false
        }

        var appleRequirement: SecRequirement?
        guard SecRequirementCreateWithString(
            "anchor apple and identifier \"\(expectedIdentity.bundleIdentifier)\"" as CFString,
            SecCSFlags(),
            &appleRequirement
        ) == errSecSuccess,
            let appleRequirement else {
            return false
        }

        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), appleRequirement) == errSecSuccess
    }

    nonisolated private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated private static func terminate(pid: pid_t) -> Bool {
        Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH
    }

}
