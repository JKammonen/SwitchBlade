import ApplicationServices
import Foundation
@testable import SwitchBladeCore

/// Diagnostic-only AX window lookup facts. Separates a failed AXWindows read
/// from a successful empty answer, counts identity successes and error codes,
/// and records owner process existence. Matching behavior is unchanged.
enum WindowLookupDiagnosticsTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("WindowLookupDiagnostics/failedReadIsNotEmptyAnswer", failedReadIsNotEmptyAnswer),
        ("WindowLookupDiagnostics/identityReadsAreCountedByErrorCode", identityReadsAreCounted),
        ("WindowLookupDiagnostics/fieldsAreCompleteAndTitleFree", fieldsAreCompleteAndTitleFree),
        ("WindowLookupDiagnostics/realLookupOfExitedProcessRecordsReadFailure", realLookupOfExitedProcess)
    ]

    private static func lookup(reads: [(id: CGWindowID?, error: Int32)], target: CGWindowID = 2,
                               total: Int? = nil) -> WindowLookupDiagnostics {
        WindowLookupDiagnostics(
            action: "activate", windowListError: 0,
            windowListOutcome: WindowLookupDiagnostics.windowListOutcome(error: 0, isWindowArray: true,
                                                                       count: total ?? reads.count),
            candidateTotal: total ?? reads.count, candidateCount: reads.count,
            candidateScanBounded: reads.count < (total ?? reads.count), identityReads: reads,
            targetWindowID: target, processAliveAtStart: true, processAliveAtEnd: true,
            windowsMs: 1, candidatesMs: 2, decisionMs: 0, matched: reads.contains { $0.id == target }
        )
    }

    static func failedReadIsNotEmptyAnswer() throws {
        let cannotComplete = AXError.cannotComplete.rawValue
        try expectEqual(WindowLookupDiagnostics.windowListOutcome(error: cannotComplete, isWindowArray: false, count: 0),
                        .readFailed)
        try expectEqual(WindowLookupDiagnostics.windowListOutcome(error: 0, isWindowArray: false, count: 0),
                        .unexpectedType)
        try expectEqual(WindowLookupDiagnostics.windowListOutcome(error: 0, isWindowArray: true, count: 0), .empty)
        try expectEqual(WindowLookupDiagnostics.windowListOutcome(error: 0, isWindowArray: true, count: 3), .listed)
    }

    static func identityReadsAreCounted() throws {
        let busy = AXError.cannotComplete.rawValue
        let reads: [(id: CGWindowID?, error: Int32)] = [
            (nil, busy), (nil, busy), (nil, WindowLookupDiagnostics.identityUnavailableError), (5, 0), (2, 0)
        ]
        let diagnostics = lookup(reads: reads, total: 40)
        try expectEqual(diagnostics.identitySuccessCount, 2)
        try expect(diagnostics.targetIdentityFound)
        try expectEqual(diagnostics.otherIdentityCount, 1)
        try expectEqual(diagnostics.identityErrorSummary, "\(busy):2,\(Int32.min):1")
        try expect(diagnostics.candidateScanBounded)
        // Listed siblings without the target: the selected ID is absent.
        let missing = lookup(reads: [(7, 0), (8, 0)])
        try expect(!missing.targetIdentityFound)
        try expectEqual(missing.otherIdentityCount, 2)
        try expect(!missing.matched)
        // Error kinds are bounded so a pathological app cannot flood the row.
        let many = lookup(reads: (1...20).map { (nil, Int32(-25_000 - $0)) })
        try expectEqual(many.identityErrorSummary.split(separator: ",").count, WindowLookupDiagnostics.maximumErrorKinds)
    }

    static func fieldsAreCompleteAndTitleFree() throws {
        let fields = lookup(reads: [(2, 0)]).fields
        for key in ["lookup_action", "matched", "window_list_outcome", "window_list_error", "candidate_total",
                    "candidate_count", "candidate_scan_bounded", "identity_success_count", "identity_error_counts",
                    "target_identity_found", "other_identity_count", "process_alive_at_start",
                    "process_alive_at_end", "windows_ms", "candidates_ms", "decision_ms"] {
            try expect(fields[key] != nil, "missing \(key)")
        }
        try expect(!fields.keys.contains { $0.contains("title") }, "lookup diagnostics never carry titles")
        try expect(WindowLookupDiagnostics.processExists(getpid()))
    }

    /// The real AX path, not an injected candidate list: an exited owner
    /// yields a failed AXWindows read, not an empty successful answer.
    @MainActor static func realLookupOfExitedProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let pid = process.processIdentifier
        try expect(!WindowLookupDiagnostics.processExists(pid))
        let captured = LockedValue<[String: PerformanceMetricValue]?>(nil)
        let previous = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            previous?(event, fields)
            if event == "activation_ax_match" { captured.value = fields }
        }
        defer { PerformanceDiagnostics.testObserver.value = previous }
        let closed = WindowActivator().close(makeItem(id: 4242, pid: pid).actionTarget)
        try expect(!closed)
        let fields = captured.value
        guard case .string(let outcome)? = fields?["window_list_outcome"],
              case .bool(let aliveAtStart)? = fields?["process_alive_at_start"],
              case .string(let action)? = fields?["lookup_action"],
              case .int(let error)? = fields?["window_list_error"] else {
            return try expect(false, "the real lookup must record its diagnostics")
        }
        try expectEqual(outcome, "read-failed")
        try expect(error != 0)
        try expect(!aliveAtStart)
        try expectEqual(action, "close")
    }
}
