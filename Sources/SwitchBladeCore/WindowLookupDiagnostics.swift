import CoreGraphics
import Darwin

/// Diagnostic only: why an AX window lookup did or did not find the selected
/// window. A failed AXWindows read, a successful empty answer, and a listed
/// window whose identity is unreadable or different are separate facts; so is
/// the owning process disappearing during the lookup. Nothing here changes
/// matching, retries or activation.
struct WindowLookupDiagnostics: Sendable {
    enum WindowListOutcome: String, Sendable {
        case readFailed = "read-failed"
        case unexpectedType = "unexpected-type"
        case empty
        case listed
    }

    /// `AXWindowIdentity` reports this when the private symbol is missing.
    static let identityUnavailableError: Int32 = Int32.min
    static let maximumErrorKinds = 6

    let action: String
    let windowListError: Int32
    let windowListOutcome: WindowListOutcome
    let candidateTotal: Int
    let candidateCount: Int
    let candidateScanBounded: Bool
    /// Raw `_AXUIElementGetWindow` result per scanned candidate.
    let identityReads: [(id: CGWindowID?, error: Int32)]
    let targetWindowID: CGWindowID
    let processAliveAtStart: Bool
    let processAliveAtEnd: Bool
    let windowsMs: Double
    let candidatesMs: Double
    let decisionMs: Double
    let matched: Bool

    var identitySuccessCount: Int { identityReads.filter { $0.id != nil }.count }
    var targetIdentityFound: Bool { identityReads.contains { $0.id == targetWindowID } }
    var otherIdentityCount: Int { identityReads.filter { $0.id != nil && $0.id != targetWindowID }.count }

    /// "code:count" for failed identity reads, most frequent first, bounded.
    var identityErrorSummary: String {
        var counts: [Int32: Int] = [:]
        for read in identityReads where read.id == nil { counts[read.error, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(Self.maximumErrorKinds)
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
    }

    var fields: [String: PerformanceMetricValue] {
        [
            "lookup_action": .string(action),
            "matched": .bool(matched),
            "window_list_outcome": .string(windowListOutcome.rawValue),
            "window_list_error": .int(Int(windowListError)),
            "candidate_total": .int(candidateTotal),
            "candidate_count": .int(candidateCount),
            "candidate_scan_bounded": .bool(candidateScanBounded),
            "identity_success_count": .int(identitySuccessCount),
            "identity_error_counts": .string(identityErrorSummary),
            "target_identity_found": .bool(targetIdentityFound),
            "other_identity_count": .int(otherIdentityCount),
            "process_alive_at_start": .bool(processAliveAtStart),
            "process_alive_at_end": .bool(processAliveAtEnd),
            "windows_ms": .double(windowsMs),
            "candidates_ms": .double(candidatesMs),
            "decision_ms": .double(decisionMs)
        ]
    }

    static func windowListOutcome(error: Int32, isWindowArray: Bool, count: Int) -> WindowListOutcome {
        guard error == 0 else { return .readFailed }
        guard isWindowArray else { return .unexpectedType }
        return count == 0 ? .empty : .listed
    }

    /// Existence, not health: EPERM still means the process exists.
    static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
