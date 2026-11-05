import CoreGraphics
import Darwin
import Foundation
import MachO

/// Building blocks for keeping exactly one SwitchBlade process that runs the
/// currently published bundle. Live proof 2026-11-05: after the bundle was
/// replaced under a running instance, apps started afterwards answered every
/// AX call from that instance with kAXErrorAPIDisabled (-25211) while other
/// clients read them normally; a relaunch fixed the same target process.

/// Process identity that survives PID reuse: start time plus boot session.
enum ProcessIdentity {
    struct StartTime: Codable, Equatable, Sendable {
        let seconds: Int64
        let microseconds: Int64
    }

    static func startTime(of pid: pid_t) -> StartTime? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return StartTime(seconds: Int64(info.pbi_start_tvsec), microseconds: Int64(info.pbi_start_tvusec))
    }

    static func bootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// An exclusive `flock` held for as long as this object (its descriptor)
/// lives. The kernel releases it when the process exits, so it cannot go
/// stale. Opened close-on-exec: a spawned child never inherits it by accident.
final class FileLock: @unchecked Sendable {
    let descriptor: Int32
    let url: URL

    private init(descriptor: Int32, url: URL) {
        self.descriptor = descriptor
        self.url = url
    }

    /// Non-blocking. `nil` when another open file description holds the lock
    /// (another process, or another acquisition in this process).
    static func acquire(at url: URL) -> FileLock? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return FileLock(descriptor: fd, url: url)
    }

    deinit { close(descriptor) }
}

/// Identity of one file on disk. Any change (including a republish of the
/// same build with an identical CDHash) counts: an unchanged code hash was
/// not proven safe for the AX permission failure, so it is not skipped.
struct FileStamp: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    static func of(_ path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileStamp(
            device: Int64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }
}

extension FileStamp {
    /// Identity of the executable this process actually mapped, from the
    /// kernel rather than the path. A publication landing between exec and
    /// the first stamp would otherwise be recorded as "already running".
    static func runningMainExecutable() -> FileStamp? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        let address = UInt64(UInt(bitPattern: header))
        guard proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, address, &info, size) == size else { return nil }
        let stat = info.prp_vip.vip_vi.vi_stat
        guard stat.vst_ino != 0 else { return nil }
        return FileStamp(
            device: Int64(stat.vst_dev), inode: UInt64(stat.vst_ino), size: Int64(stat.vst_size),
            modifiedSeconds: Int64(stat.vst_mtime), modifiedNanoseconds: Int64(stat.vst_mtimensec)
        )
    }
}

struct BundleStamp: Equatable, Sendable {
    let executable: FileStamp?
    let infoPlist: FileStamp?

    /// Launch identity: the mapped executable from the kernel; the plist as on
    /// disk now (it is not mapped code).
    static func launch(bundleURL: URL, executableURL: URL) -> BundleStamp {
        BundleStamp(
            executable: FileStamp.runningMainExecutable() ?? FileStamp.of(executableURL.path),
            infoPlist: FileStamp.of(bundleURL.appendingPathComponent("Contents/Info.plist").path)
        )
    }

    static func of(bundleURL: URL, executableURL: URL) -> BundleStamp {
        BundleStamp(
            executable: FileStamp.of(executableURL.path),
            infoPlist: FileStamp.of(bundleURL.appendingPathComponent("Contents/Info.plist").path)
        )
    }

    enum Change: String, Sendable {
        case unchanged
        /// A path is missing right now (mid-publication or removed). Not yet
        /// actionable; the next check decides.
        case unavailable
        case replaced
    }

    func change(to current: BundleStamp) -> Change {
        guard let executable, let infoPlist else { return .unavailable }
        guard let currentExecutable = current.executable, let currentInfo = current.infoPlist else {
            return .unavailable
        }
        return executable == currentExecutable && infoPlist == currentInfo ? .unchanged : .replaced
    }
}

/// Short-lived, one-shot window-rank handoff across a relaunch. Holds window
/// IDs and process identities only: no titles, no previews.
struct RelaunchHandoff: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let windowID: CGWindowID
        let appPID: pid_t
        let appStart: ProcessIdentity.StartTime
        let ownerPID: pid_t
        let ownerStart: ProcessIdentity.StartTime
    }

    static let currentVersion = 1
    static let maximumAgeSeconds: TimeInterval = 60

    let version: Int
    let requestID: String
    let bootSessionUUID: String
    let createdAt: Date
    /// Most recent first.
    let entries: [Entry]

    enum Rejection: String, Error, Sendable {
        case missing, unreadable, wrongVersion, wrongRequest, otherBootSession, expired
    }

    func validate(requestID expected: String, bootSessionUUID boot: String?, now: Date) -> Rejection? {
        guard version == Self.currentVersion else { return .wrongVersion }
        guard requestID == expected else { return .wrongRequest }
        guard let boot, boot == bootSessionUUID else { return .otherBootSession }
        let age = now.timeIntervalSince(createdAt)
        guard age >= -5, age <= Self.maximumAgeSeconds else { return .expired }
        return nil
    }

    /// Live windows to replay, most recent first. A rank survives only when
    /// the same window ID is listed by the same owner process, and both the
    /// app process and a separate owner process kept their start time.
    static func restorableItems(
        _ entries: [Entry],
        in liveItems: [WindowItem],
        startTime: (pid_t) -> ProcessIdentity.StartTime?
    ) -> [WindowItem] {
        let live = Dictionary(liveItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.compactMap { entry in
            guard let item = live[entry.windowID],
                  item.pid == entry.appPID,
                  item.windowProcessIdentifier == entry.ownerPID,
                  startTime(entry.appPID) == entry.appStart,
                  startTime(entry.ownerPID) == entry.ownerStart else { return nil }
            return item
        }
    }

    static func make(
        requestID: String, bootSessionUUID: String, now: Date,
        rankedItems: [WindowItem], startTime: (pid_t) -> ProcessIdentity.StartTime?
    ) -> RelaunchHandoff {
        let entries = rankedItems.compactMap { item -> Entry? in
            guard !item.isApplicationFallback, !SyntheticWindowID.isSynthetic(item.id),
                  let appStart = startTime(item.pid),
                  let ownerStart = startTime(item.windowProcessIdentifier) else { return nil }
            return Entry(windowID: item.id, appPID: item.pid, appStart: appStart,
                         ownerPID: item.windowProcessIdentifier, ownerStart: ownerStart)
        }
        return RelaunchHandoff(version: currentVersion, requestID: requestID, bootSessionUUID: bootSessionUUID,
                               createdAt: now, entries: entries)
    }
}

/// File locations shared by the running instance, the relaunch helper and
/// the relaunched instance. Injectable so tests never touch the real ones.
struct RelaunchPaths: Sendable {
    let directory: URL

    static var standard: RelaunchPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return RelaunchPaths(directory: base.appendingPathComponent("SwitchBlade", isDirectory: true))
    }

    var instanceLock: URL { directory.appendingPathComponent("instance.lock") }
    var relaunchLock: URL { directory.appendingPathComponent("relaunch.lock") }
    var handoff: URL { directory.appendingPathComponent("relaunch-handoff.json") }
    var helperLog: URL { directory.appendingPathComponent("relaunch.log") }
    func ack(for requestID: String) -> URL { directory.appendingPathComponent("relaunch-ack-\(requestID)") }
    var crashBeforeAckFault: URL { directory.appendingPathComponent("fault-crash-before-relaunch-ack") }
    var corruptHandoffFault: URL { directory.appendingPathComponent("fault-corrupt-relaunch-handoff") }

    func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// Written to a temporary sibling and renamed: a reader sees all or nothing.
    func writeAtomically(_ data: Data, to url: URL) throws {
        ensureDirectory()
        let temporary = url.appendingPathExtension("tmp-\(getpid())")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Reads and deletes in one step: a handoff is consumed at most once.
    func consumeHandoff() -> Data? {
        let data = try? Data(contentsOf: handoff)
        try? FileManager.default.removeItem(at: handoff)
        return data
    }
}

enum RelaunchLaunchArguments {
    static let requestFlag = "--switchblade-relaunch-request"

    static func requestID(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: requestFlag), arguments.indices.contains(index + 1) else {
            return nil
        }
        let value = arguments[index + 1]
        // UUID text only: it becomes part of a file name.
        return UUID(uuidString: value) != nil ? value : nil
    }
}
