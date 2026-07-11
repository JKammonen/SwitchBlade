import Foundation
@testable import SwitchBladeCore

enum SecureInputMonitorTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("SecureInputMonitor/parsesSecureInputPID", parsesSecureInputPID),
        ("SecureInputMonitor/currentState_marksDeadPIDStale", currentStateMarksDeadPIDStale),
        ("SecureInputMonitor/cleanupTargetsForStalePID_doesNotGuess", cleanupTargetsForStalePIDDoesNotGuess),
        ("SecureInputMonitor/cleanupTargetsForLiveUserApp_isEmpty", cleanupTargetsForLiveUserAppIsEmpty),
        ("SecureInputMonitor/cleanupTargetsForUntrustedNamesake_isEmpty", cleanupTargetsForUntrustedNamesakeIsEmpty),
        ("SecureInputMonitor/cleanupTargetsForWrongAppleBundle_isEmpty", cleanupTargetsForWrongAppleBundleIsEmpty),
        ("SecureInputMonitor/validationRunsOffMainActor", validationRunsOffMainActor),
        ("SecureInputMonitor/cleanupSkipsReusedPID", cleanupSkipsReusedPID),
        ("SecureInputMonitor/cleanupSkipsUnverifiedProcessGeneration", cleanupSkipsUnverifiedProcessGeneration),
        ("SecureInputMonitor/cleanupSkipsOwnerPIDChange", cleanupSkipsOwnerPIDChange),
        ("SecureInputMonitor/cleanupTerminatesExactSafeOwner", cleanupTerminatesExactSafeOwner)
    ]

    @MainActor static func parsesSecureInputPID() throws {
        let users: [Any] = [
            ["kCGSSessionUserNameKey": "jannekammonen"],
            ["kCGSSessionSecureInputPID": NSNumber(value: 36557)]
        ]

        try expectEqual(SecureInputMonitor.secureInputPID(from: users), 36557)
    }

    @MainActor static func currentStateMarksDeadPIDStale() throws {
        let monitor = SecureInputMonitor(
            readSecureInputPID: { 36557 },
            resolveProcess: { _ in nil },
            terminateProcess: { _ in true }
        )

        let state = monitor.currentState()

        try expectEqual(state.pid, 36557)
        try expect(state.isStale)
    }

    @MainActor static func cleanupTargetsForStalePIDDoesNotGuess() throws {
        let monitor = SecureInputMonitor(
            readSecureInputPID: { 36557 },
            resolveProcess: { _ in nil },
            terminateProcess: { _ in true }
        )

        let targets = monitor.safeCleanupTargets(for: monitor.currentState())

        try expectEqual(targets, [])
    }

    @MainActor static func cleanupTargetsForLiveUserAppIsEmpty() throws {
        let preview = process(pid: 36557, executableName: "Preview")
        let monitor = SecureInputMonitor(
            readSecureInputPID: { 36557 },
            resolveProcess: { _ in preview },
            terminateProcess: { _ in true }
        )

        try expect(monitor.safeCleanupTargets(for: monitor.currentState()).isEmpty)
    }

    @MainActor static func cleanupTerminatesExactSafeOwner() async throws {
        let safeQuickLook = process(
            pid: 36557,
            executableName: "QuickLookUIService",
            bundleIdentifier: "com.apple.quicklook.QuickLookUIService",
            isTrustedAppleSystemExecutable: true
        )
        var killed: [pid_t] = []
        var active = true
        let monitor = SecureInputMonitor(
            readSecureInputPID: { active ? 36557 : nil },
            resolveProcess: { _ in active ? safeQuickLook : nil },
            terminateProcess: { pid in
                killed.append(pid)
                active = false
                return true
            },
            recheckDelayNanoseconds: 0
        )

        let result = await monitor.clearStuckSecureInput()

        try expectEqual(killed, [36557])
        try expectEqual(result.terminated, [safeQuickLook])
        try expect(!result.after.isActive)
    }

    @MainActor static func cleanupTargetsForUntrustedNamesakeIsEmpty() throws {
        let impostor = process(
            pid: 36557,
            executableName: "QuickLookUIService",
            bundleIdentifier: "com.example.QuickLookUIService",
            isTrustedAppleSystemExecutable: false
        )
        let monitor = SecureInputMonitor(
            readSecureInputPID: { 36557 },
            resolveProcess: { _ in impostor },
            terminateProcess: { _ in true }
        )

        try expect(monitor.safeCleanupTargets(for: monitor.currentState()).isEmpty)
    }

    @MainActor static func cleanupSkipsReusedPID() async throws {
        let safeQuickLook = process(
            pid: 36557,
            executableName: "QuickLookUIService",
            bundleIdentifier: "com.apple.quicklook.QuickLookUIService",
            isTrustedAppleSystemExecutable: true
        )
        let reusedPID = process(
            pid: 36557,
            executableName: "QuickLookUIService",
            bundleIdentifier: "com.apple.quicklook.QuickLookUIService",
            startTimeMicroseconds: 2,
            isTrustedAppleSystemExecutable: true
        )
        var resolutionCount = 0
        var killed: [pid_t] = []
        let monitor = SecureInputMonitor(
            readSecureInputPID: { 36557 },
            resolveProcess: { _ in
                resolutionCount += 1
                return resolutionCount == 1 ? safeQuickLook : reusedPID
            },
            terminateProcess: { pid in
                killed.append(pid)
                return true
            },
            recheckDelayNanoseconds: 0
        )

        let result = await monitor.clearStuckSecureInput()

        try expectEqual(killed, [])
        try expectEqual(result.terminated, [])
        try expect(result.after.isActive)
    }

    @MainActor static func cleanupTargetsForWrongAppleBundleIsEmpty() throws {
        let wrongAppleIdentity = process(
            pid: 36557,
            executableName: "QuickLookUIService",
            bundleIdentifier: "com.apple.NotQuickLook",
            isTrustedAppleSystemExecutable: true
        )
        let monitor = SecureInputMonitor(
            readSecureInputPID: { 36557 },
            resolveProcess: { _ in wrongAppleIdentity },
            terminateProcess: { _ in true }
        )

        try expect(monitor.safeCleanupTargets(for: monitor.currentState()).isEmpty)
    }

    @MainActor static func validationRunsOffMainActor() async throws {
        let unresolved = process(
            pid: 36557,
            executableName: "QuickLookUIService",
            bundleIdentifier: "com.apple.quicklook.QuickLookUIService",
            isTrustedAppleSystemExecutable: false
        )
        let validationRanOnMainThread = LockedValue(true)
        let monitor = SecureInputMonitor(
            readSecureInputPID: { 36557 },
            resolveProcess: { _ in unresolved },
            terminateProcess: { _ in true },
            validateExecutableTrust: { _ in
                validationRanOnMainThread.value = Thread.isMainThread
                return true
            }
        )

        let state = await monitor.validatedCurrentState()

        try expect(state.process?.isTrustedAppleSystemExecutable == true)
        try expect(!validationRanOnMainThread.value)
    }

    @MainActor static func cleanupSkipsOwnerPIDChange() async throws {
        let safeQuickLook = process(
            pid: 36557,
            executableName: "QuickLookUIService",
            bundleIdentifier: "com.apple.quicklook.QuickLookUIService",
            isTrustedAppleSystemExecutable: true
        )
        var pidReadCount = 0
        var killed: [pid_t] = []
        let monitor = SecureInputMonitor(
            readSecureInputPID: {
                pidReadCount += 1
                return pidReadCount == 1 ? 36557 : 77777
            },
            resolveProcess: { pid in pid == 36557 ? safeQuickLook : nil },
            terminateProcess: { pid in
                killed.append(pid)
                return true
            },
            recheckDelayNanoseconds: 0
        )

        let result = await monitor.clearStuckSecureInput()

        try expectEqual(killed, [])
        try expectEqual(result.terminated, [])
        try expectEqual(result.after.pid, 77777)
    }

    @MainActor static func cleanupSkipsUnverifiedProcessGeneration() async throws {
        let unresolvedGeneration = process(
            pid: 36557,
            executableName: "QuickLookUIService",
            bundleIdentifier: "com.apple.quicklook.QuickLookUIService",
            startTimeMicroseconds: nil,
            isTrustedAppleSystemExecutable: true
        )
        var killed: [pid_t] = []
        let monitor = SecureInputMonitor(
            readSecureInputPID: { 36557 },
            resolveProcess: { _ in unresolvedGeneration },
            terminateProcess: { pid in
                killed.append(pid)
                return true
            },
            recheckDelayNanoseconds: 0
        )

        let result = await monitor.clearStuckSecureInput()

        try expectEqual(killed, [])
        try expectEqual(result.terminated, [])
    }

    private static func process(
        pid: pid_t,
        executableName: String,
        bundleIdentifier: String? = nil,
        startTimeMicroseconds: UInt64? = 1,
        isTrustedAppleSystemExecutable: Bool = false
    ) -> SecureInputProcess {
        SecureInputProcess(
            pid: pid,
            displayName: executableName,
            bundleIdentifier: bundleIdentifier,
            executablePath: executableName == "QuickLookUIService"
                ? "/System/Library/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIService.xpc/Contents/MacOS/QuickLookUIService"
                : "/System/Library/\(executableName)",
            startTimeMicroseconds: startTimeMicroseconds,
            isTrustedAppleSystemExecutable: isTrustedAppleSystemExecutable
        )
    }
}
