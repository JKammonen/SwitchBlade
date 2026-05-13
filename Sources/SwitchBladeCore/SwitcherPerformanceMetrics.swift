import Foundation

struct RollingMetricSummary: Equatable {
    let count: Int
    let latest: Double
    let average: Double
    let p50: Double
    let p95: Double
    let p99: Double
    let max: Double
}

struct RollingMetric {
    private let capacity: Int
    private var samples: [Double] = []

    init(capacity: Int = 100) {
        precondition(capacity > 0, "RollingMetric capacity must be positive")
        self.capacity = capacity
    }

    mutating func record(_ value: Double) -> RollingMetricSummary {
        samples.append(value)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }

        let sorted = samples.sorted()
        let sum = samples.reduce(0, +)
        return RollingMetricSummary(
            count: samples.count,
            latest: value,
            average: sum / Double(samples.count),
            p50: percentile(50, in: sorted),
            p95: percentile(95, in: sorted),
            p99: percentile(99, in: sorted),
            max: sorted.last ?? value
        )
    }

    private func percentile(_ p: Double, in sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int(ceil((p / 100) * Double(sorted.count))) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

@MainActor
final class SwitcherPerformanceMetrics {
    private var coldOpen = RollingMetric(capacity: 100)
    private var firstPreviewBatch = RollingMetric(capacity: 100)

    func recordColdOpen(milliseconds: Double) -> RollingMetricSummary {
        coldOpen.record(milliseconds)
    }

    func recordFirstPreviewBatch(milliseconds: Double) -> RollingMetricSummary {
        firstPreviewBatch.record(milliseconds)
    }
}
