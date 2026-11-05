import CoreGraphics
import Darwin
import Foundation
import MachO

/// Building blocks for running exactly one SwitchBlade on the published
/// bundle. Live proof 2026-11-05: after the bundle was replaced under a running
/// instance, apps started afterwards answered every AX call from that instance
/// with kAXErrorAPIDisabled (-25211) while other clients read them normally; a
/// relaunch fixed the same target process. `build-app.sh` therefore stops the
/// running instance before publishing and relaunches it afterwards.

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
/// stale. Opened close-on-exec: a spawned child never inherits it.
final class FileLock: @unchecked Sendable {
    let descriptor: Int32
    let url: URL

    enum Acquisition {
        case acquired(FileLock)
        /// Another open file description holds it: another instance runs.
        case held
        /// The lock file could not be opened at all (errno); this says
        /// nothing about other instances.
        case unavailable(Int32)
    }

    private init(descriptor: Int32, url: URL) {
        self.descriptor = descriptor
        self.url = url
    }

    static func attempt(at url: URL) -> Acquisition {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(fd)
            return error == EWOULDBLOCK ? .held : .unavailable(error)
        }
        return .acquired(FileLock(descriptor: fd, url: url))
    }

    /// Non-blocking convenience: `nil` unless acquired.
    static func acquire(at url: URL) -> FileLock? {
        if case .acquired(let lock) = attempt(at: url) { return lock }
        return nil
    }

    deinit { close(descriptor) }
}

/// Identity of one file on disk.
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

    /// Identity of the executable this process actually mapped, from the
    /// kernel rather than the path: a publication landing between exec and the
    /// first check is still seen.
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

/// Window-rank handoff written on graceful termination and read once by the
/// next launch. Window IDs, owner process identity and app identity only: no
/// titles, no previews.
struct RelaunchHandoff: Codable, Equatable, Sendable {
    /// One MRU rank. Concrete windows carry their owner process identity;
    /// synthetic minimized rows carry the owner known to the switcher;
    /// app-level ranks carry only the app identity. Order is the MRU order.
    struct Entry: Codable, Equatable, Sendable {
        let windowID: CGWindowID?
        let ownerPID: pid_t?
        let ownerStart: ProcessIdentity.StartTime?
        /// Bundle identifier or app name: the rank's app identity. No titles.
        let appIdentity: String
    }

    /// A rank to hand over: `windowID` nil for an app-level rank;
    /// `knownOwnerPID` for synthetic rows WindowServer does not list.
    struct Rank: Equatable, Sendable {
        let windowID: CGWindowID?
        let appIdentity: String
        let knownOwnerPID: pid_t?
    }

    static let currentVersion = 4
    /// Covers stop, publish and relaunch by the build script with margin.
    static let maximumAgeSeconds: TimeInterval = 120

    let version: Int
    let bootSessionUUID: String
    let createdAt: Date
    /// Most recent first.
    let entries: [Entry]

    enum Rejection: String, Error, Sendable {
        case missing, unreadable, wrongVersion, otherBootSession, expired
    }

    func validate(bootSessionUUID boot: String?, now: Date) -> Rejection? {
        guard version == Self.currentVersion else { return .wrongVersion }
        guard let boot, boot == bootSessionUUID else { return .otherBootSession }
        let age = now.timeIntervalSince(createdAt)
        guard age >= -5, age <= Self.maximumAgeSeconds else { return .expired }
        return nil
    }

    static func make(
        bootSessionUUID: String, now: Date, ranks: [Rank],
        windowOwners: [CGWindowID: pid_t], startTime: (pid_t) -> ProcessIdentity.StartTime?
    ) -> RelaunchHandoff {
        let entries = ranks.compactMap { rank -> Entry? in
            guard let id = rank.windowID else {
                return Entry(windowID: nil, ownerPID: nil, ownerStart: nil, appIdentity: rank.appIdentity)
            }
            let owner = SyntheticWindowID.isSynthetic(id) ? rank.knownOwnerPID : windowOwners[id]
            guard let owner, let start = startTime(owner) else { return nil }
            return Entry(windowID: id, ownerPID: owner, ownerStart: start, appIdentity: rank.appIdentity)
        }
        return RelaunchHandoff(version: currentVersion, bootSessionUUID: bootSessionUUID, createdAt: now,
                               entries: entries)
    }

    /// Concrete windows: WindowServer still lists the same ID for the same
    /// owner and the owner kept its start time. Synthetic rows: the owner kept
    /// its start time (the same process recomputes the same ID). App-level
    /// ranks always survive.
    static func restorableEntries(
        _ entries: [Entry], windowOwners: [CGWindowID: pid_t], startTime: (pid_t) -> ProcessIdentity.StartTime?
    ) -> [Entry] {
        entries.filter { entry in
            guard let id = entry.windowID else { return true }
            guard let owner = entry.ownerPID, startTime(owner) == entry.ownerStart else { return false }
            return SyntheticWindowID.isSynthetic(id) || windowOwners[id] == owner
        }
    }

    /// Every window WindowServer knows (all Spaces, minimized included),
    /// window ID → owner PID. Identity only: no titles are read.
    static func currentWindowOwners() -> [CGWindowID: pid_t] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var owners: [CGWindowID: pid_t] = [:]
        for entry in list {
            guard let id = entry[kCGWindowNumber as String] as? UInt32,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32 else { continue }
            owners[id] = pid
        }
        return owners
    }
}

/// Files shared by the running instance and `build-app.sh`. Injectable so
/// tests never touch the real ones.
struct LifecyclePaths: Sendable {
    let directory: URL
    var fallbackDirectory = URL(fileURLWithPath: NSTemporaryDirectory())

    static var standard: LifecyclePaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return LifecyclePaths(directory: base.appendingPathComponent("SwitchBlade", isDirectory: true))
    }

    var instanceLock: URL { directory.appendingPathComponent("instance.lock") }
    /// Used when the Application Support lock cannot be opened at all.
    var fallbackInstanceLock: URL {
        fallbackDirectory.appendingPathComponent("com.jannekammonen.SwitchBlade.instance.lock")
    }
    var handoff: URL { directory.appendingPathComponent("relaunch-handoff.json") }
    /// "<pid> <executable inode> <unix time>" once launch setup finished;
    /// `build-app.sh` accepts a relaunch only from this marker.
    var readyMarker: URL { directory.appendingPathComponent("ready") }

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
}
