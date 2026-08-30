import AppKit
import Foundation

struct MinimizedAXScanCandidate: Equatable {
    let windowProcessIdentifier: pid_t
    let hostProcessIdentifier: pid_t
    let activationPolicy: NSApplication.ActivationPolicy
}

enum MinimizedAXScanPlan {
    private enum Priority: Int {
        case regularApplication
        case nestedAccessory
        case standaloneAccessoryWithWindowServerEvidence
        case standaloneAccessory
    }

    /// WindowServer ordering and NSWorkspace ordering are both incidental. Keep
    /// every eligible process in the plan, but put the processes most likely to
    /// own user windows first so the elapsed-time safety bound cannot be consumed
    /// by dozens of empty standalone accessory applications.
    static func ordered(
        _ candidates: [MinimizedAXScanCandidate],
        windowServerProcessIdentifiers: Set<pid_t>
    ) -> [MinimizedAXScanCandidate] {
        candidates.enumerated().sorted { lhs, rhs in
            let lhsPriority = priority(
                for: lhs.element,
                windowServerProcessIdentifiers: windowServerProcessIdentifiers
            )
            let rhsPriority = priority(
                for: rhs.element,
                windowServerProcessIdentifiers: windowServerProcessIdentifiers
            )
            if lhsPriority != rhsPriority {
                return lhsPriority.rawValue < rhsPriority.rawValue
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func priority(
        for candidate: MinimizedAXScanCandidate,
        windowServerProcessIdentifiers: Set<pid_t>
    ) -> Priority {
        if candidate.activationPolicy == .regular {
            return .regularApplication
        }
        if candidate.windowProcessIdentifier != candidate.hostProcessIdentifier {
            return .nestedAccessory
        }
        if windowServerProcessIdentifiers.contains(candidate.windowProcessIdentifier) {
            return .standaloneAccessoryWithWindowServerEvidence
        }
        return .standaloneAccessory
    }
}

struct MinimizedAXScanExecutionResult<Item> {
    let items: [Item]
    let scannedApplications: Int
    let scannedWindows: Int
    let applicationsWithoutWindows: Int
    let applicationsWithUnavailableAX: Int
    let isBudgetExhausted: Bool
    let isComplete: Bool
}

enum MinimizedAXScanExecution {
    /// Runs the complete candidate traversal while leaving AX access and item
    /// construction injectable. This keeps the production budget/cancellation
    /// contract deterministic enough to test at the same scale as the live scan.
    static func run<Candidate, Window, Item>(
        candidates: [Candidate],
        maximumWindows: Int,
        maximumElapsedSeconds: TimeInterval,
        startedAt: TimeInterval,
        now: () -> TimeInterval,
        isCancelled: () -> Bool,
        windowsForCandidate: (Candidate) -> [Window]?,
        itemForWindow: (Candidate, Int, Window) -> Item?
    ) -> MinimizedAXScanExecutionResult<Item> {
        var budget = AXScanBudget(
            maximumApplications: candidates.count,
            maximumWindows: maximumWindows,
            maximumElapsedSeconds: maximumElapsedSeconds,
            startedAt: startedAt
        )
        var items: [Item] = []
        var applicationsWithoutWindows = 0
        var applicationsWithUnavailableAX = 0

        candidateLoop: for candidate in candidates {
            if isCancelled() { break }
            guard budget.beginApplication(now: now()) else { break }
            guard let windows = windowsForCandidate(candidate) else {
                applicationsWithUnavailableAX += 1
                continue
            }
            if windows.isEmpty {
                applicationsWithoutWindows += 1
            }
            for (index, window) in windows.enumerated() {
                if isCancelled() { break candidateLoop }
                guard budget.beginWindow(now: now()) else { break candidateLoop }
                if let item = itemForWindow(candidate, index, window) {
                    items.append(item)
                }
            }
        }

        let isComplete = !isCancelled()
            && !budget.isExhausted
            && budget.scannedApplications == candidates.count
        return MinimizedAXScanExecutionResult(
            items: items,
            scannedApplications: budget.scannedApplications,
            scannedWindows: budget.scannedWindows,
            applicationsWithoutWindows: applicationsWithoutWindows,
            applicationsWithUnavailableAX: applicationsWithUnavailableAX,
            isBudgetExhausted: budget.isExhausted,
            isComplete: isComplete
        )
    }
}
