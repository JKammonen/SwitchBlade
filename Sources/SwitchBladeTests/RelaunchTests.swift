import AppKit
import Darwin
import Foundation
@testable import SwitchBladeCore

/// Lifecycle of the single running instance. `build-app.sh` stops, publishes
/// and relaunches (its shell side is covered by scripts/test-relaunch-lifecycle.sh);
/// these tests cover the app side: lock, graceful quit gate, rank handoff,
/// ready marker and replacement warning, against temporary files.
enum RelaunchTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("Relaunch/instanceLockIsExclusiveAndCloseOnExec", instanceLockIsExclusive),
        ("Relaunch/concurrentAcquisitionsYieldExactlyOneOwner", concurrentAcquisitions),
        ("Relaunch/unopenableLockIsNotAnotherInstance", unopenableLockIsNotAnotherInstance),
        ("Relaunch/spawnedShellInheritsNoLock", spawnedShellInheritsNoLock),
        ("Relaunch/quitWaitsForIdleAtMostThreeSeconds", quitWaitsForIdle),
        ("Relaunch/store_idleGateWaitsForDetachedWindowAction", storeIdleGate),
        ("Relaunch/handoffKeepsMinimizedAndOtherSpaceRanksWithoutTitles", handoffKeepsAllRanks),
        ("Relaunch/takeHandoffRestoresOnlyUnchangedOwnersOnce", takeHandoffRestoresOnlyUnchanged),
        ("Relaunch/takeHandoffRejectsStaleForeignAndCorrupt", takeHandoffRejects),
        ("Relaunch/store_exportsAndRestores14RanksInOrder", storeRanksRoundTrip),
        ("Relaunch/readyMarkerNamesThisProcessAndMappedInode", readyMarker),
        ("Relaunch/replacementOutsideBuildScriptWarnsOnce", replacementWarnsOnce),
        ("Relaunch/mappedExecutableIdentityMatchesUnreplacedFile", mappedExecutableIdentity),
        ("Relaunch/launchWarmupCapturesEveryPreviewInScope", launchWarmupCapturesAll)
    ]

    private static func temporaryPaths() -> LifecyclePaths {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchblade-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
        var paths = LifecyclePaths(directory: directory)
        paths.fallbackDirectory = directory.appendingPathComponent("fallback", isDirectory: true)
        paths.ensureDirectory()
        try? FileManager.default.createDirectory(at: paths.fallbackDirectory, withIntermediateDirectories: true)
        return paths
    }

    private static let start = ProcessIdentity.StartTime(seconds: 1_000, microseconds: 7)

    static func instanceLockIsExclusive() throws {
        let paths = temporaryPaths()
        var first = FileLock.acquire(at: paths.instanceLock)
        try expectNotNil(first)
        guard case .held = FileLock.attempt(at: paths.instanceLock) else {
            return try expect(false, "a second open description must see the lock as held")
        }
        try expect(fcntl(first!.descriptor, F_GETFD) & FD_CLOEXEC != 0, "never inherited by a spawned child")
        first = nil
        try expectNotNil(FileLock.acquire(at: paths.instanceLock), "released with its descriptor")
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

    /// An unopenable lock file says nothing about other instances: the
    /// fallback lock decides, and only a held lock means "another runs".
    @MainActor static func unopenableLockIsNotAnotherInstance() throws {
        var paths = temporaryPaths()
        let blocker = paths.directory.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let fallback = paths.fallbackDirectory
        paths = LifecyclePaths(directory: blocker)
        paths.fallbackDirectory = fallback
        guard case .unavailable = FileLock.attempt(at: paths.instanceLock) else {
            return try expect(false, "a lock under a file cannot be opened")
        }
        guard case .acquired(let locks) = InstanceLifecycle.acquireInstanceLock(paths: paths) else {
            return try expect(false, "the fallback lock must be used")
        }
        try expectEqual(locks.count, 1)
        guard case .anotherInstanceRuns = InstanceLifecycle.acquireInstanceLock(paths: paths) else {
            return try expect(false, "a second instance must see the fallback lock held")
        }
        // A later instance that CAN open the primary lock is still excluded.
        var healthy = LifecyclePaths(directory: temporaryPaths().directory)
        healthy.fallbackDirectory = fallback
        guard case .anotherInstanceRuns = InstanceLifecycle.acquireInstanceLock(paths: healthy) else {
            return try expect(false, "an instance on the fallback lock must exclude one on the primary")
        }
        withExtendedLifetime(locks) {}
    }

    @MainActor static func spawnedShellInheritsNoLock() throws {
        let paths = temporaryPaths()
        var lock = FileLock.acquire(at: paths.instanceLock)
        try expectNotNil(lock)
        guard let pid = InstanceLifecycle.spawnDetachedShell(script: "/bin/sleep 1", arguments: []) else {
            return try expect(false, "spawn failed")
        }
        lock = nil
        try expectNotNil(FileLock.acquire(at: paths.instanceLock), "the restart helper must not hold the lock")
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    @MainActor static func quitWaitsForIdle() throws {
        try expect(InstanceLifecycle.shouldQuitNow(isIdle: true, waited: 0))
        try expect(!InstanceLifecycle.shouldQuitNow(isIdle: false, waited: 2.9), "a switch in progress is not cut off")
        try expect(InstanceLifecycle.shouldQuitNow(isIdle: false, waited: 3), "a busy app cannot block publication")
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

    /// Ranks are resolved against every window WindowServer lists, so a
    /// minimized window or one on another Space keeps its rank.
    static func handoffKeepsAllRanks() throws {
        let synthetic = SyntheticWindowID.make(pid: 600, index: 0, title: "Quarterly secret")
        let ranks = [
            RelaunchHandoff.Rank(windowID: 5, appIdentity: "com.example.mail", knownOwnerPID: nil),
            RelaunchHandoff.Rank(windowID: nil, appIdentity: "com.example.app-level", knownOwnerPID: nil),
            RelaunchHandoff.Rank(windowID: synthetic, appIdentity: "com.example.notes", knownOwnerPID: 600),
            RelaunchHandoff.Rank(windowID: 9, appIdentity: "com.example.minimized", knownOwnerPID: nil),
            RelaunchHandoff.Rank(windowID: 7, appIdentity: "com.example.gone", knownOwnerPID: nil)
        ]
        let owners: [CGWindowID: pid_t] = [5: 500, 9: 900]   // 9 is minimized/other Space; 7 has closed
        let handoff = RelaunchHandoff.make(bootSessionUUID: "boot", now: Date(), ranks: ranks,
                                           windowOwners: owners, startTime: { _ in start })
        try expectEqual(handoff.entries.map(\.windowID), [5, nil, synthetic, 9], "MRU order kept, closed window dropped")
        let text = String(decoding: try JSONEncoder().encode(handoff), as: UTF8.self)
        try expect(!text.contains("Quarterly"), "no titles in the handoff")
        let restored = RelaunchHandoff.restorableEntries(handoff.entries, windowOwners: owners) { pid in
            pid == 600 ? ProcessIdentity.StartTime(seconds: 9, microseconds: 9) : start
        }
        try expectEqual(restored.map(\.windowID), [5, nil, 9], "a synthetic row of a restarted owner is dropped")
    }

    private static func write(_ handoff: RelaunchHandoff, to paths: LifecyclePaths) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try paths.writeAtomically(try encoder.encode(handoff), to: paths.handoff)
    }

    private static func entry(_ id: CGWindowID, owner: pid_t) -> RelaunchHandoff.Entry {
        RelaunchHandoff.Entry(windowID: id, ownerPID: owner, ownerStart: start, appIdentity: "app.\(id)")
    }

    @MainActor static func takeHandoffRestoresOnlyUnchanged() throws {
        let paths = temporaryPaths()
        let entries = (1...14).map { entry(CGWindowID($0), owner: pid_t(100 + $0)) }
        try write(RelaunchHandoff(version: RelaunchHandoff.currentVersion, bootSessionUUID: "boot", createdAt: Date(),
                                  entries: entries), to: paths)
        var owners = Dictionary(uniqueKeysWithValues: (1...14).map { (CGWindowID($0), pid_t(100 + $0)) })
        owners[4] = 999          // window 4 now belongs to another process
        owners[6] = nil          // window 6 closed
        let restarted: pid_t = 108
        let other = ProcessIdentity.StartTime(seconds: 2_000, microseconds: 0)
        let taken = InstanceLifecycle.takeHandoff(paths: paths, windowOwners: owners,
                                                  startTime: { $0 == restarted ? other : start },
                                                  bootSessionUUID: "boot")
        try expectNil(taken.rejection)
        try expectEqual(taken.entries.map(\.windowID), [1, 2, 3, 5, 7, 9, 10, 11, 12, 13, 14],
                        "order kept; moved, closed and restarted-owner windows dropped")
        try expect(!FileManager.default.fileExists(atPath: paths.handoff.path), "one launch consumes it")
        try expectEqual(InstanceLifecycle.takeHandoff(paths: paths, bootSessionUUID: "boot").rejection, .missing)
    }

    @MainActor static func takeHandoffRejects() throws {
        let paths = temporaryPaths()
        let fresh = RelaunchHandoff(version: RelaunchHandoff.currentVersion, bootSessionUUID: "boot",
                                    createdAt: Date(), entries: [entry(1, owner: 101)])
        let owners: [CGWindowID: pid_t] = [1: 101]
        try write(fresh, to: paths)
        try expectEqual(InstanceLifecycle.takeHandoff(paths: paths, windowOwners: owners, startTime: { _ in start },
                                                      bootSessionUUID: "other").rejection, .otherBootSession)
        try write(fresh, to: paths)
        try expectEqual(InstanceLifecycle.takeHandoff(paths: paths, now: Date().addingTimeInterval(121),
                                                      windowOwners: owners, startTime: { _ in start },
                                                      bootSessionUUID: "boot").rejection, .expired)
        try write(RelaunchHandoff(version: 2, bootSessionUUID: "boot", createdAt: Date(), entries: []), to: paths)
        try expectEqual(InstanceLifecycle.takeHandoff(paths: paths, bootSessionUUID: "boot").rejection, .wrongVersion)
        try paths.writeAtomically(Data("corrupt".utf8), to: paths.handoff)
        try expectEqual(InstanceLifecycle.takeHandoff(paths: paths, bootSessionUUID: "boot").rejection, .unreadable)
        try expect(!FileManager.default.fileExists(atPath: paths.handoff.path), "a bad handoff is discarded")
    }

    /// Export from MRU ranks, not from the visible snapshot: windows outside
    /// the current scope keep their rank; import restores the same order.
    @MainActor static func storeRanksRoundTrip() async throws {
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let (store, catalog, _, _) = makeStore(mruTracker: tracker, initialFrontmostAppPID: 100)
        defer { store.cancel() }
        catalog.visibleItems = []   // nothing visible in the current scope
        let order: [CGWindowID] = [9, 3, 14, 1, 7, 2, 12, 5, 11, 4, 13, 6, 10, 8]
        for id in order.reversed() {
            tracker.trackFocusedWindowActivation(makeItem(id: id, pid: pid_t(100 * Int(id)), bundleIdentifier: "app.\(id)"))
        }
        tracker.trackSystemActivation(4242, in: [], bundleIdentifier: "app.level")   // app-level rank on top
        let exported = store.relaunchRanks()
        try expectEqual(exported.map(\.windowID), [nil] + order.map { Optional($0) })
        let fresh = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let (restoredStore, _, _, _) = makeStore(mruTracker: fresh, initialFrontmostAppPID: 100)
        defer { restoredStore.cancel() }
        let entries = exported.map { RelaunchHandoff.Entry(windowID: $0.windowID, ownerPID: 1, ownerStart: start,
                                                           appIdentity: $0.appIdentity) }
        try expectEqual(restoredStore.applyRelaunchRanks(entries), 15)
        try expectEqual(Array(fresh.recentWindowIDs.prefix(14)), order)
        try expectEqual(fresh.identityOnlyRankIdentities.first, exported.first?.appIdentity)
    }

    @MainActor static func readyMarker() throws {
        let paths = temporaryPaths()
        let lifecycle = InstanceLifecycle(paths: paths, bundleURL: paths.directory,
                                          executableURL: URL(fileURLWithPath: CommandLine.arguments[0]))
        try expect(lifecycle.writeReadyMarker(now: Date(timeIntervalSince1970: 1_700_000_000)))
        let parts = try String(contentsOf: paths.readyMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        try expectEqual(parts.count, 3)
        try expectEqual(pid_t(parts[0]), getpid())
        try expectEqual(UInt64(parts[1]), FileStamp.runningMainExecutable()?.inode,
                        "the inode of the code this process really runs")
        try expectEqual(parts[2], "1700000000")
    }

    private static func ownExecutablePath() throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else {
            throw TestFailure(message: "no path", file: #filePath, line: #line)
        }
        return String(cString: buffer)
    }

    @MainActor static func replacementWarnsOnce() throws {
        let paths = temporaryPaths()
        let own = URL(fileURLWithPath: try ownExecutablePath())
        let unchanged = InstanceLifecycle(paths: paths, bundleURL: paths.directory, executableURL: own)
        var unchangedCalls = 0
        unchanged.onReplacementDetected = { unchangedCalls += 1 }
        unchanged.checkForReplacement()
        try expectEqual(unchangedCalls, 0, "the running executable is unchanged")
        // A path whose file is not the mapped executable stands for a replaced bundle.
        let other = paths.directory.appendingPathComponent("replaced")
        try Data("x".utf8).write(to: other)
        let replaced = InstanceLifecycle(paths: paths, bundleURL: paths.directory, executableURL: other)
        var calls = 0
        replaced.onReplacementDetected = { calls += 1 }
        replaced.checkForReplacement()
        replaced.checkForReplacement()
        try expectEqual(calls, 1, "the warning is raised once")
        try expect(replaced.replacementDetected)
    }

    static func mappedExecutableIdentity() throws {
        guard let mapped = FileStamp.runningMainExecutable() else {
            return try expect(false, "mapped executable identity unavailable")
        }
        try expectEqual(mapped, FileStamp.of(try ownExecutablePath()))
    }

    /// After a relaunch the preview cache is empty: the launch warmup must
    /// fill every capturable window so the first open shows previews, while a
    /// routine warmup keeps the four-window budget.
    @MainActor static func launchWarmupCapturesAll() async throws {
        for (limit, expected) in [(Int?.none, 13), (Int?.some(4), 4)] {
            let (store, catalog, _, _) = makeStore(initialFrontmostAppPID: 100)
            defer { store.cancel() }
            let items = (1...13).map { makeItem(id: CGWindowID($0), pid: pid_t(100 * $0), isFrontmostApp: $0 == 1) }
            catalog.visibleItems = items
            catalog.previewsToReturn = Dictionary(uniqueKeysWithValues: items.map {
                ($0.id, NSImage(size: NSSize(width: 8, height: 8)))
            })
            await store.warmPreviewCache(context: "test", limit: limit)
            try expectEqual(Set(catalog.captureWindowIDCalls.flatMap { $0 }).count, expected)
            store.requestCycle(forward: true)
            try expectEqual(store.items.filter { $0.preview != nil }.count, expected,
                            "first paint after the warmup")
        }
    }
}
