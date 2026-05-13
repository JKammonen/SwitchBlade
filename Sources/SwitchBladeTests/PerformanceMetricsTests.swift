@testable import SwitchBladeCore

enum PerformanceMetricsTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("PerformanceMetrics/rollingPercentiles_useNearestRank", rollingPercentiles),
        ("PerformanceMetrics/rollingWindow_capsAtCapacity", rollingWindowCapsAtCapacity)
    ]

    @MainActor static func rollingPercentiles() throws {
        var metric = RollingMetric(capacity: 100)
        var summary: RollingMetricSummary?
        for value in 1...100 {
            summary = metric.record(Double(value))
        }

        try expectEqual(summary?.count, 100)
        try expectEqual(summary?.p50, 50)
        try expectEqual(summary?.p95, 95)
        try expectEqual(summary?.p99, 99)
        try expectEqual(summary?.max, 100)
    }

    @MainActor static func rollingWindowCapsAtCapacity() throws {
        var metric = RollingMetric(capacity: 3)
        _ = metric.record(10)
        _ = metric.record(20)
        _ = metric.record(30)
        let summary = metric.record(40)

        try expectEqual(summary.count, 3)
        try expectEqual(summary.p50, 30)
        try expectEqual(summary.p95, 40)
        try expectEqual(summary.max, 40)
    }
}
