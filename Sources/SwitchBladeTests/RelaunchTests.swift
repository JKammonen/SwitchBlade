import AppKit
import Darwin
import Foundation
import Security
@testable import SwitchBladeCore

/// One instance running the published bundle. Locks, replacement detection,
/// idle gating, the one-shot rank handoff and descriptor inheritance run for
/// real against temporary files; launching the app itself is covered by the
/// signed-app acceptance runs, not here.
enum RelaunchTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("Relaunch/instanceLockIsExclusiveAndCloseOnExec", instanceLockIsExclusive),
        ("Relaunch/concurrentAcquisitionsYieldExactlyOneOwner", concurrentAcquisitions),
        ("Relaunch/bundleStampDetectsReplacementIncludingSameBytes", bundleStampDetectsReplacement),
        ("Relaunch/handoffValidationRejectsStaleForeignAndCorrupt", handoffValidation),
        ("Relaunch/handoffRestoresOnlyIdenticalProcessesAndOwners", handoffRestoresOnlyIdentical),
        ("Relaunch/handoffCarriesNoTitles", handoffCarriesNoTitles),
        ("Relaunch/requestIDMustBeUUID", requestIDMustBeUUID),
        ("Relaunch/helperInheritsRelaunchLockButNotInstanceLock", helperInheritance),
        ("Relaunch/completeConsumesHandoffOnceAndAcknowledges", completeConsumesHandoffOnce),
        ("Relaunch/store_idleGateWaitsForDetachedWindowAction", storeIdleGate),
        ("Relaunch/store_handoffRestores14WindowOrder", storeHandoffRestoresOrder),
        ("Relaunch/faultFilesAreCountedAndAbsentByDefault", faultFilesAreCounted),
        ("Relaunch/signatureCheckRejectsOtherOrBrokenBundles", signatureCheck),
        ("Relaunch/mappedExecutableIdentityMatchesUnreplacedFile", mappedExecutableIdentity)
    ]

    private static func temporaryPaths() -> RelaunchPaths {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchblade-relaunch-tests-\(UUID().uuidString)", isDirectory: true)
        let paths = RelaunchPaths(directory: directory)
        paths.ensureDirectory()
        return paths
    }

    static func instanceLockIsExclusive() throws {
        let paths = temporaryPaths()
        var first = FileLock.acquire(at: paths.instanceLock)
        try expectNotNil(first)
        try expectNil(FileLock.acquire(at: paths.instanceLock), "a second open description must not get the lock")
        let flags = fcntl(first!.descriptor, F_GETFD)
        try expect(flags & FD_CLOEXEC != 0, "the instance lock must not leak into spawned children")
        first = nil
        try expectNotNil(FileLock.acquire(at: paths.instanceLock), "the lock is released with its descriptor")
    }

    /// Two simultaneous starts: exactly one wins; neither both nor none.
    static func concurrentAcquisitions() throws {
        for _ in 0..<20 {
            let paths = temporaryPaths()
            let results = LockedValue<[FileLock?]>([])
            let group = DispatchGroup()
            for _ in 0..<2 {
                group.enter()
                DispatchQueue.global().async {
                    let lock = FileLock.acquire(at: paths.instanceLock)
                    results.withValue { $0.append(lock) }
                    group.leave()
                }
            }
            group.wait()
            try expectEqual(results.value.compactMap { $0 }.count, 1)
        }
    }

    static func bundleStampDetectsReplacement() throws {
        let paths = temporaryPaths()
        let bundle = paths.directory.appendingPathComponent("Fake.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/Fake")
        func publish(_ text: String) throws {
            let staging = paths.directory.appendingPathComponent("staging-\(UUID().uuidString).app")
            try FileManager.default.createDirectory(at: staging.appendingPathComponent("Contents/MacOS"),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: staging.appendingPathComponent("Contents/MacOS/Fake"))
            try Data("plist".utf8).write(to: staging.appendingPathComponent("Contents/Info.plist"))
            if FileManager.default.fileExists(atPath: bundle.path) {
                _ = try FileManager.default.replaceItemAt(bundle, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: bundle)
            }
        }
        try publish("build-1")
        let launch = BundleStamp.of(bundleURL: bundle, executableURL: executable)
        try expectEqual(launch.change(to: BundleStamp.of(bundleURL: bundle, executableURL: executable)), .unchanged)
        try publish("build-1")
        try expectEqual(launch.change(to: BundleStamp.of(bundleURL: bundle, executableURL: executable)), .replaced,
                        "a republish of identical bytes still replaces the files")
        try FileManager.default.removeItem(at: bundle)
        try expectEqual(launch.change(to: BundleStamp.of(bundleURL: bundle, executableURL: executable)), .unavailable,
                        "a missing bundle is not yet actionable")
    }

    private static let start = ProcessIdentity.StartTime(seconds: 1_000, microseconds: 7)

    private static func handoff(requestID: String = "A", boot: String = "boot-1", createdAt: Date = Date(),
                                version: Int = RelaunchHandoff.currentVersion) -> RelaunchHandoff {
        RelaunchHandoff(version: version, requestID: requestID, bootSessionUUID: boot, createdAt: createdAt, entries: [])
    }

    @MainActor static func handoffValidation() throws {
        let now = Date()
        try expectNil(handoff().validate(requestID: "A", bootSessionUUID: "boot-1", now: now))
        try expectEqual(handoff(version: 99).validate(requestID: "A", bootSessionUUID: "boot-1", now: now), .wrongVersion)
        try expectEqual(handoff(requestID: "B").validate(requestID: "A", bootSessionUUID: "boot-1", now: now), .wrongRequest)
        try expectEqual(handoff(boot: "boot-0").validate(requestID: "A", bootSessionUUID: "boot-1", now: now),
                        .otherBootSession)
        try expectEqual(handoff().validate(requestID: "A", bootSessionUUID: nil, now: now), .otherBootSession)
        try expectEqual(handoff(createdAt: now.addingTimeInterval(-61)).validate(requestID: "A", bootSessionUUID: "boot-1",
                                                                                 now: now), .expired)
        try expectEqual(handoff(createdAt: now.addingTimeInterval(30)).validate(requestID: "A", bootSessionUUID: "boot-1",
                                                                                now: now), .expired)
        let paths = temporaryPaths()
        let requestID = UUID().uuidString
        try paths.writeAtomically(Data("not json".utf8), to: paths.handoff)
        let rejection = LockedValue<RelaunchHandoff.Rejection?>(nil)
        RelaunchCoordinator.completeRelaunch(requestID: requestID, paths: paths) { entries, reason in
            rejection.value = reason
            return entries?.count ?? 0
        }
        try expectEqual(rejection.value, .unreadable, "a corrupt handoff is ignored, not trusted")
        RelaunchCoordinator.completeRelaunch(requestID: requestID, paths: paths) { entries, reason in
            rejection.value = reason
            return entries?.count ?? 0
        }
        try expectEqual(rejection.value, .missing, "a consumed handoff is not mistaken for a corrupt one")
    }

    static func handoffRestoresOnlyIdentical() throws {
        let other = ProcessIdentity.StartTime(seconds: 2_000, microseconds: 0)
        let live = (1...14).map { makeItem(id: CGWindowID($0), pid: pid_t(100 + $0)) }
            + [makeItem(id: 50, pid: 400, windowOwnerPID: 401)]
        var entries = live.map {
            RelaunchHandoff.Entry(windowID: $0.id, appPID: $0.pid, appStart: start,
                                  ownerPID: $0.windowProcessIdentifier, ownerStart: start)
        }
        entries.append(RelaunchHandoff.Entry(windowID: 99, appPID: 999, appStart: start, ownerPID: 999, ownerStart: start))
        let restarted: pid_t = 103          // app relaunched with the same PID
        let ownerRestarted: pid_t = 401     // separate window owner restarted
        let restored = RelaunchHandoff.restorableItems(entries, in: live) { pid in
            pid == restarted || pid == ownerRestarted ? other : start
        }
        try expectEqual(restored.map(\.id), (1...14).filter { $0 != 3 }.map { CGWindowID($0) },
                        "order kept; changed app, changed owner and vanished window dropped")
        // A window now owned by a different process is not the same window.
        let moved = RelaunchHandoff.restorableItems(
            [RelaunchHandoff.Entry(windowID: 1, appPID: 101, appStart: start, ownerPID: 777, ownerStart: start)],
            in: live, startTime: { _ in start }
        )
        try expect(moved.isEmpty)
    }

    static func handoffCarriesNoTitles() throws {
        let items = [makeItem(id: 1, pid: 100, title: "Quarterly secret"),
                     makeItem(id: SyntheticWindowID.make(pid: 100, index: 0, title: "x"), pid: 100, title: "x")]
        let handoff = RelaunchHandoff.make(requestID: "A", bootSessionUUID: "boot-1", now: Date(),
                                           rankedItems: items, startTime: { _ in start })
        try expectEqual(handoff.entries.map(\.windowID), [1], "synthetic rows have no concrete identity to hand over")
        let text = String(decoding: try JSONEncoder().encode(handoff), as: UTF8.self)
        try expect(!text.contains("Quarterly"), "no titles in the handoff file")
    }

    static func requestIDMustBeUUID() throws {
        let id = UUID().uuidString
        try expectEqual(RelaunchLaunchArguments.requestID(in: ["app", RelaunchLaunchArguments.requestFlag, id]), id)
        try expectNil(RelaunchLaunchArguments.requestID(in: ["app", RelaunchLaunchArguments.requestFlag, "../x"]))
        try expectNil(RelaunchLaunchArguments.requestID(in: ["app"]))
    }

    /// The helper must keep the relaunch lock after the old process exits,
    /// and must never hold the instance lock (the new instance needs it).
    @MainActor static func helperInheritance() throws {
        let paths = temporaryPaths()
        var instance = FileLock.acquire(at: paths.instanceLock)
        var relaunch = FileLock.acquire(at: paths.relaunchLock)
        try expectNotNil(instance)
        guard let pid = RelaunchCoordinator.spawnDetachedShell(
            script: "/bin/sleep 1", arguments: [], inheritedDescriptor: relaunch!.descriptor,
            logPath: paths.helperLog.path
        ) else { return try expect(false, "spawn failed") }
        instance = nil
        relaunch = nil
        try expectNotNil(FileLock.acquire(at: paths.instanceLock), "the helper did not inherit the instance lock")
        try expectNil(FileLock.acquire(at: paths.relaunchLock), "the helper holds the relaunch lock")
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        try expectNotNil(FileLock.acquire(at: paths.relaunchLock), "released when the helper exits")
    }

    @MainActor static func completeConsumesHandoffOnce() throws {
        let paths = temporaryPaths()
        let requestID = UUID().uuidString
        guard let boot = ProcessIdentity.bootSessionUUID() else { return try expect(false, "no boot session") }
        let entry = RelaunchHandoff.Entry(windowID: 7, appPID: 1, appStart: start, ownerPID: 1, ownerStart: start)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(RelaunchHandoff(version: RelaunchHandoff.currentVersion, requestID: requestID,
                                                      bootSessionUUID: boot, createdAt: Date(), entries: [entry]))
        try paths.writeAtomically(data, to: paths.handoff)
        let received = LockedValue<[RelaunchHandoff.Entry]?>(nil)
        let ackExistedDuringApply = LockedValue(true)
        RelaunchCoordinator.completeRelaunch(requestID: requestID, paths: paths) { entries, _ in
            received.value = entries
            ackExistedDuringApply.value = FileManager.default.fileExists(atPath: paths.ack(for: requestID).path)
            return entries?.count ?? 0
        }
        try expectEqual(received.value, [entry])
        try expect(!ackExistedDuringApply.value, "readiness is acknowledged only after the handoff is applied")
        try expect(!FileManager.default.fileExists(atPath: paths.handoff.path), "the handoff is one-shot")
        let ack = try String(contentsOf: paths.ack(for: requestID), encoding: .utf8)
        try expect(ack.hasPrefix("\(requestID) \(getpid())"))
    }

    @MainActor static func storeIdleGate() async throws {
        let (store, catalog, activator, _) = makeStore(initialFrontmostAppPID: 100)
        defer { store.cancel() }
        catalog.visibleItems = [makeItem(id: 1, pid: 100, isFrontmostApp: true), makeItem(id: 2, pid: 200)]
        try expect(store.isIdleForRelaunch)
        activator.actionDelayNanoseconds = 300_000_000
        await openSwitcher(store)
        try expect(!store.isIdleForRelaunch, "an open switcher is not idle")
        store.selectedID = 2
        store.commitSelection()
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(!store.isVisible)
        try expect(!store.isIdleForRelaunch, "a dismissed panel can still own detached AX work")
        for _ in 0..<100 where !store.isIdleForRelaunch { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(store.isIdleForRelaunch)
    }

    @MainActor static func storeHandoffRestoresOrder() async throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let (store, catalog, _, _) = makeStore(mruTracker: tracker, initialFrontmostAppPID: 100)
        defer { store.cancel() }
        let live = (1...14).map { makeItem(id: CGWindowID($0), pid: pid_t(100 * $0)) }
        catalog.visibleItems = live
        let order: [CGWindowID] = [9, 3, 14, 1, 7, 2, 12, 5, 11, 4, 13, 6, 10, 8]
        let entries = order.map { id in
            RelaunchHandoff.Entry(windowID: id, appPID: pid_t(100 * Int(id)), appStart: start,
                                  ownerPID: pid_t(100 * Int(id)), ownerStart: start)
        }
        let restored = store.applyRelaunchHandoff(entries, startTime: { _ in start })
        try expectEqual(restored, 14)
        try expectEqual(Array(tracker.recentWindowIDs.prefix(14)), order)
    }

    @MainActor static func faultFilesAreCounted() throws {
        let paths = temporaryPaths()
        try expect(!RelaunchCoordinator.consumeFault(paths.crashBeforeAckFault), "no fault without its file")
        try Data("2".utf8).write(to: paths.crashBeforeAckFault)
        try expect(RelaunchCoordinator.consumeFault(paths.crashBeforeAckFault))
        try expect(RelaunchCoordinator.consumeFault(paths.crashBeforeAckFault))
        try expect(!RelaunchCoordinator.consumeFault(paths.crashBeforeAckFault))
        try expect(!FileManager.default.fileExists(atPath: paths.crashBeforeAckFault.path))
    }

    /// Real code-signing checks on ad-hoc signed temporary bundles: the
    /// relaunch only proceeds into a bundle that is validly signed by the
    /// requirement captured at launch.
    @MainActor static func signatureCheck() throws {
        let paths = temporaryPaths()
        func makeBundle(_ name: String, binary: String) throws -> URL {
            let bundle = paths.directory.appendingPathComponent("\(name).app")
            let macOS = bundle.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: binary, toPath: macOS.appendingPathComponent("Fake").path)
            let plist: [String: Any] = ["CFBundleIdentifier": "test.switchblade.fake", "CFBundleExecutable": "Fake"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
            return bundle
        }
        func requirement(of bundle: URL) throws -> String {
            var code: SecStaticCode?
            var requirement: SecRequirement?
            var text: CFString?
            guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
                  SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
                  SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
                throw TestFailure(message: "no designated requirement", file: #filePath, line: #line)
            }
            return text as String
        }
        let original = try makeBundle("Original", binary: "/usr/bin/true")
        let launchRequirement = try requirement(of: original)
        try expect(RelaunchCoordinator.bundle(original, satisfies: launchRequirement))
        let other = try makeBundle("Other", binary: "/usr/bin/false")
        try expect(!RelaunchCoordinator.bundle(other, satisfies: launchRequirement), "different code, other requirement")
        // Fallback when the launch requirement was unreadable: only a bundle
        // with the same identifier supplies its own requirement.
        try expectNotNil(RelaunchCoordinator.diskRequirement(of: other, bundleIdentifier: "test.switchblade.fake"))
        try expectNil(RelaunchCoordinator.diskRequirement(of: other, bundleIdentifier: "com.jannekammonen.SwitchBlade"))
        let executable = original.appendingPathComponent("Contents/MacOS/Fake")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(atPath: "/usr/bin/false", toPath: executable.path)
        try expect(!RelaunchCoordinator.bundle(original, satisfies: launchRequirement), "tampered bundle is rejected")
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestFailure(message: "\(tool) failed", file: #filePath, line: #line)
        }
    }

    /// The kernel's identity of this process's mapped executable equals the
    /// file at its path while that file is unreplaced; the launch stamp uses
    /// the former so a publication racing the first stamp is still seen.
    static func mappedExecutableIdentity() throws {
        guard let mapped = FileStamp.runningMainExecutable() else {
            return try expect(false, "mapped executable identity unavailable")
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return try expect(false, "no path") }
        let path = String(cString: buffer)
        try expectEqual(mapped, FileStamp.of(path))
    }
}
