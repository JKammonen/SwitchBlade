import AppKit
import Darwin
import Foundation
import IOKit
import os.log

struct SecureInputProcess: Equatable {
    let pid: pid_t
    let displayName: String
    let bundleIdentifier: String?
    let executablePath: String?

    var executableName: String {
        executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? displayName
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

final class SecureInputMonitor {
    typealias PIDReader = () -> pid_t?
    typealias ProcessResolver = (pid_t) -> SecureInputProcess?
    typealias ProcessLister = () -> [SecureInputProcess]
    typealias Terminator = (pid_t) -> Bool

    private let readSecureInputPID: PIDReader
    private let resolveProcess: ProcessResolver
    private let listProcesses: ProcessLister
    private let terminateProcess: Terminator

    init(
        readSecureInputPID: @escaping PIDReader = SecureInputMonitor.readSecureInputPIDFromIORegistry,
        resolveProcess: @escaping ProcessResolver = SecureInputMonitor.processInfo,
        listProcesses: @escaping ProcessLister = SecureInputMonitor.runningProcesses,
        terminateProcess: @escaping Terminator = SecureInputMonitor.terminate
    ) {
        self.readSecureInputPID = readSecureInputPID
        self.resolveProcess = resolveProcess
        self.listProcesses = listProcesses
        self.terminateProcess = terminateProcess
    }

    func currentState() -> SecureInputState {
        guard let pid = readSecureInputPID() else {
            return .inactive
        }
        return SecureInputState(pid: pid, process: resolveProcess(pid))
    }

    func safeCleanupTargets(for state: SecureInputState) -> [SecureInputProcess] {
        guard state.isActive else { return [] }

        let safeHelpers = listProcesses().filter(Self.isSafeCleanupTarget)
        var targets: [SecureInputProcess] = []

        if let process = state.process, Self.isSafeCleanupTarget(process) {
            targets.append(process)
        }

        if state.isStale {
            targets.append(contentsOf: safeHelpers)
        }

        return Self.uniqueProcesses(targets)
    }

    func clearStuckSecureInput() -> SecureInputCleanupResult {
        let before = currentState()
        let targets = safeCleanupTargets(for: before)
        let terminated = targets.filter { terminateProcess($0.pid) }

        if !terminated.isEmpty {
            Thread.sleep(forTimeInterval: 0.4)
        }

        let after = currentState()
        return SecureInputCleanupResult(before: before, terminated: terminated, after: after)
    }

    static func secureInputPID(from consoleUsers: Any?) -> pid_t? {
        guard let users = consoleUsers as? [Any] else { return nil }

        for case let user as [String: Any] in users {
            if let pid = pidValue(user["kCGSSessionSecureInputPID"]) {
                return pid
            }
        }
        return nil
    }

    static func isSafeCleanupTarget(_ process: SecureInputProcess) -> Bool {
        safeCleanupExecutableNames.contains(process.executableName)
    }

    private static let safeCleanupExecutableNames: Set<String> = [
        "QuickLookUIService",
        "com.apple.quicklook.ThumbnailsAgent",
        "TextInputMenuAgent",
        "TextInputSwitcher",
        "CursorUIViewService"
    ]

    private static func readSecureInputPIDFromIORegistry() -> pid_t? {
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

    private static func pidValue(_ value: Any?) -> pid_t? {
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

    private static func processInfo(pid: pid_t) -> SecureInputProcess? {
        guard pid > 0 else { return nil }
        if Darwin.kill(pid, 0) == -1 && errno == ESRCH {
            return nil
        }

        let runningApp = NSRunningApplication(processIdentifier: pid)
        let executablePath = runningApp?.executableURL?.path ?? executablePath(pid: pid)
        let displayName = runningApp?.localizedName
            ?? executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "pid \(pid)"

        return SecureInputProcess(
            pid: pid,
            displayName: displayName,
            bundleIdentifier: runningApp?.bundleIdentifier,
            executablePath: executablePath
        )
    }

    private static func runningProcesses() -> [SecureInputProcess] {
        let pidSize = MemoryLayout<pid_t>.stride
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(bytesNeeded) / pidSize)
        let bytesWritten = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &pids,
            Int32(pids.count * pidSize)
        )
        guard bytesWritten > 0 else { return [] }

        return pids
            .prefix(Int(bytesWritten) / pidSize)
            .filter { $0 > 0 }
            .compactMap(processInfo(pid:))
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func terminate(pid: pid_t) -> Bool {
        Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH
    }

    private static func uniqueProcesses(_ processes: [SecureInputProcess]) -> [SecureInputProcess] {
        var seen = Set<pid_t>()
        var result: [SecureInputProcess] = []
        for process in processes where seen.insert(process.pid).inserted {
            result.append(process)
        }
        return result
    }
}
