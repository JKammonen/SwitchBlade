import Foundation
@testable import SwitchBladeCore

enum SecureInputMonitorTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("SecureInputMonitor/parsesSecureInputPID", parsesSecureInputPID),
        ("SecureInputMonitor/currentState_marksDeadPIDStale", currentStateMarksDeadPIDStale),
        ("SecureInputMonitor/cleanupTargetsForStalePID_onlySafeHelpers", cleanupTargetsForStalePIDOnlySafeHelpers),
        ("SecureInputMonitor/cleanupTargetsForLiveUserApp_isEmpty", cleanupTargetsForLiveUserAppIsEmpty),
        ("SecureInputMonitor/cleanupTerminatesSafeTargets", cleanupTerminatesSafeTargets)
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
            listProcesses: { [] },
            terminateProcess: { _ in true }
        )

        let state = monitor.currentState()

        try expectEqual(state.pid, 36557)
        try expect(state.isStale)
    }

    @MainActor static func cleanupTargetsForStalePIDOnlySafeHelpers() throws {
        let safeQuickLook = process(pid: 100, executableName: "QuickLookUIService")
        let safeTextInput = process(pid: 101, executableName: "TextInputMenuAgent")
        let unsafePreview = process(pid: 102, executableName: "Preview")
        let monitor = SecureInputMonitor(
            readSecureInputPID: { 36557 },
            resolveProcess: { _ in nil },
            listProcesses: { [safeQuickLook, safeTextInput, unsafePreview] },
            terminateProcess: { _ in true }
        )

        let targets = monitor.safeCleanupTargets(for: monitor.currentState())

        try expectEqual(targets, [safeQuickLook, safeTextInput])
    }

    @MainActor static func cleanupTargetsForLiveUserAppIsEmpty() throws {
        let preview = process(pid: 36557, executableName: "Preview")
        let monitor = SecureInputMonitor(
            readSecureInputPID: { 36557 },
            resolveProcess: { _ in preview },
            listProcesses: { [process(pid: 100, executableName: "QuickLookUIService")] },
            terminateProcess: { _ in true }
        )

        try expect(monitor.safeCleanupTargets(for: monitor.currentState()).isEmpty)
    }

    @MainActor static func cleanupTerminatesSafeTargets() throws {
        let safeQuickLook = process(pid: 100, executableName: "QuickLookUIService")
        var killed: [pid_t] = []
        var active = true
        let monitor = SecureInputMonitor(
            readSecureInputPID: { active ? 36557 : nil },
            resolveProcess: { _ in nil },
            listProcesses: { [safeQuickLook, process(pid: 102, executableName: "Preview")] },
            terminateProcess: { pid in
                killed.append(pid)
                active = false
                return true
            }
        )

        let result = monitor.clearStuckSecureInput()

        try expectEqual(killed, [100])
        try expectEqual(result.terminated, [safeQuickLook])
        try expect(!result.after.isActive)
    }

    private static func process(pid: pid_t, executableName: String) -> SecureInputProcess {
        SecureInputProcess(
            pid: pid,
            displayName: executableName,
            bundleIdentifier: nil,
            executablePath: "/System/Library/\(executableName)"
        )
    }
}
