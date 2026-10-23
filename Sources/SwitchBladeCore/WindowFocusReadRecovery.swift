import ApplicationServices
import Foundation

/// Recover communication failures while the same app still owns user focus.
/// Notifications only request an actual focused-window read; their own window
/// is never focus evidence. One bounded sequence serves all notification types.
@MainActor
final class WindowFocusReadRecovery {
    struct Request {
        let pid: pid_t
        let trigger: String
        let invalidatesMembership: Bool
        let diagnosticID: String
        let attempt: Int
    }

    enum Result {
        case captured(WindowFocusCapture)
        case failure(AXError, String)
    }

    private let retryDelays: [UInt64]
    private let frontmostPID: () -> pid_t?
    private let isAllowed: () -> Bool
    private let read: (Request) -> Result
    private let deliver: (WindowFocusCapture) -> Void
    private var generation = 0
    private var pending: Request?
    private var retryTask: Task<Void, Never>?

    init(retryDelays: [UInt64] = [150_000_000, 350_000_000, 700_000_000],
         frontmostPID: @escaping () -> pid_t?, isAllowed: @escaping () -> Bool,
         read: @escaping (Request) -> Result, deliver: @escaping (WindowFocusCapture) -> Void) {
        self.retryDelays = retryDelays
        self.frontmostPID = frontmostPID
        self.isAllowed = isAllowed
        self.read = read
        self.deliver = deliver
    }

    func capture(pid: pid_t, trigger: String, invalidatesMembership: Bool = true) {
        // A registration retry must not erase a pending membership invalidation.
        let invalidates = invalidatesMembership || (pending?.pid == pid && pending?.invalidatesMembership == true)
        cancel(reason: "superseded")
        let request = Request(pid: pid, trigger: trigger, invalidatesMembership: invalidates,
                              diagnosticID: UUID().uuidString, attempt: 0)
        pending = request
        attempt(request, generation: generation)
    }

    func cancel(reason: String) {
        generation &+= 1
        retryTask?.cancel()
        retryTask = nil
        if let pending { record(pending, outcome: "cancelled", reason: reason) }
        pending = nil
    }

    private func attempt(_ request: Request, generation: Int) {
        guard self.generation == generation else { return }
        let before = frontmostPID()
        guard isAllowed(), before == request.pid else {
            record(request, outcome: "discarded-not-eligible", before: before)
            pending = nil
            return
        }
        let result = read(request)
        let after = frontmostPID()
        // Also guard against cancellation/reentrant notifications during AX IPC.
        guard self.generation == generation else { return }
        guard isAllowed(), after == request.pid else {
            record(request, outcome: "discarded-frontmost-changed", before: before, after: after, afterRead: true)
            pending = nil
            return
        }
        switch result {
        case .captured(let capture):
            pending = nil
            record(request, outcome: "captured", before: before, after: after, afterRead: true)
            deliver(capture)
        case .failure(let error, let outcome):
            record(request, outcome: outcome, error: error, before: before, after: after, afterRead: true)
            guard error == .cannotComplete, request.attempt < retryDelays.count else {
                pending = nil
                if error == .cannotComplete { record(request, outcome: "retry-exhausted", error: error) }
                return
            }
            let delay = retryDelays[request.attempt]
            record(request, outcome: "retry-scheduled", error: error, delay: delay)
            retryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.retryTask = nil
                let next = Request(pid: request.pid, trigger: request.trigger,
                                   invalidatesMembership: request.invalidatesMembership,
                                   diagnosticID: request.diagnosticID, attempt: request.attempt + 1)
                self.pending = next
                self.attempt(next, generation: generation)
            }
        }
    }

    private func record(_ request: Request, outcome: String, reason: String = "", error: AXError = .success,
                        before: pid_t? = nil, after: pid_t? = nil, afterRead: Bool = false, delay: UInt64 = 0) {
        PerformanceDiagnostics.$correlationID.withValue(request.diagnosticID) {
            PerformanceDiagnostics.record("focus_observer_capture", fields: [
                "pid": .int(Int(request.pid)), "trigger": .string(request.trigger),
                "attempt": .int(request.attempt), "outcome": .string(outcome), "reason": .string(reason),
                "ax_error": .int(Int(error.rawValue)), "retry_delay_ms": .double(Double(delay) / 1_000_000),
                "frontmost_before_pid": .int(Int(before ?? -1)), "frontmost_after_pid": .int(Int(after ?? -1)),
                "frontmost_after_read": .bool(afterRead)
            ])
        }
    }

    deinit { retryTask?.cancel() }
}
