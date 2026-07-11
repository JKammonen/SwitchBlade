import Foundation
@testable import SwitchBladeCore

enum PerformanceDiagnosticsTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("PerformanceDiagnostics/metricLine_includesTimestampEventAndFields", lineIncludesTimestampEventAndFields),
        ("PerformanceDiagnostics/metricLine_serializesEachValueType", lineSerializesEachValueType),
        ("PerformanceDiagnostics/metricLine_sortsKeys", lineSortsKeys),
        ("PerformanceDiagnostics/metricLine_endsWithNewline", lineEndsWithNewline),
        ("PerformanceDiagnostics/panelHideMetric_containsTimingBreakdown", panelHideMetricContainsTimingBreakdown),
        ("PerformanceDiagnostics/stringFields_areLengthBounded", stringFieldsAreLengthBounded),
        ("PerformanceDiagnostics/fieldCountAndKeys_areLengthBounded", fieldCountAndKeysAreLengthBounded),
        ("PerformanceDiagnostics/logRotation_isSizeBounded", logRotationIsSizeBounded)
    ]

    private static func decode(
        _ line: Data,
        file: String = #file,
        line lineNumber: Int = #line
    ) throws -> [String: Any] {
        // Drop the trailing newline before decoding the JSON object.
        let json = line.dropLast()
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw TestFailure(message: "metric line did not decode to a JSON object", file: file, line: lineNumber)
        }
        return object
    }

    static func lineIncludesTimestampEventAndFields() throws {
        let line = try PerformanceDiagnostics.metricLine(
            event: "panel_show",
            fields: ["count": .int(3)],
            timestamp: "2026-06-18T12:00:00.000Z"
        )
        let object = try decode(line)

        try expectEqual(object["timestamp"] as? String, "2026-06-18T12:00:00.000Z")
        try expectEqual(object["event"] as? String, "panel_show")
        try expectEqual(object["count"] as? Int, 3)
    }

    static func lineSerializesEachValueType() throws {
        let line = try PerformanceDiagnostics.metricLine(
            event: "capture_previews",
            fields: [
                "ok": .bool(true),
                "elapsed_ms": .double(12.5),
                "n": .int(7),
                "scope": .string("current")
            ],
            timestamp: "2026-06-18T12:00:00.000Z"
        )
        let object = try decode(line)

        try expectEqual(object["ok"] as? Bool, true)
        try expectEqual(object["elapsed_ms"] as? Double, 12.5)
        try expectEqual(object["n"] as? Int, 7)
        try expectEqual(object["scope"] as? String, "current")
    }

    static func lineSortsKeys() throws {
        let line = try PerformanceDiagnostics.metricLine(
            event: "e",
            fields: ["zeta": .int(1), "alpha": .int(2)],
            timestamp: "t"
        )
        guard let text = String(data: line, encoding: .utf8) else {
            throw TestFailure(message: "metric line was not valid UTF-8", file: #file, line: #line)
        }
        // sortedKeys is the contract that keeps performance.jsonl diff-stable.
        let alpha = text.range(of: "\"alpha\"")
        let event = text.range(of: "\"event\"")
        let timestamp = text.range(of: "\"timestamp\"")
        let zeta = text.range(of: "\"zeta\"")
        try expectNotNil(alpha)
        try expect(alpha!.lowerBound < event!.lowerBound)
        try expect(event!.lowerBound < timestamp!.lowerBound)
        try expect(timestamp!.lowerBound < zeta!.lowerBound)
    }

    static func lineEndsWithNewline() throws {
        let line = try PerformanceDiagnostics.metricLine(
            event: "e",
            fields: [:],
            timestamp: "t"
        )
        try expectEqual(line.last, 0x0A)
        // Exactly one newline — the line is one JSONL record.
        try expectEqual(line.filter { $0 == 0x0A }.count, 1)
    }

    static func panelHideMetricContainsTimingBreakdown() throws {
        let line = try PerformanceDiagnostics.metricLine(
            event: "panel_hide",
            fields: [
                "click_monitor_ms": .double(1.0),
                "flush_ms": .double(2.0),
                "milliseconds": .double(7.5),
                "order_out_ms": .double(3.0),
                "transaction_ms": .double(1.5),
                "was_visible": .bool(true)
            ],
            timestamp: "2026-06-29T12:00:00.000Z"
        )
        let object = try decode(line)

        try expectEqual(object["event"] as? String, "panel_hide")
        try expectEqual(object["click_monitor_ms"] as? Double, 1.0)
        try expectEqual(object["flush_ms"] as? Double, 2.0)
        try expectEqual(object["milliseconds"] as? Double, 7.5)
        try expectEqual(object["order_out_ms"] as? Double, 3.0)
        try expectEqual(object["transaction_ms"] as? Double, 1.5)
        try expectEqual(object["was_visible"] as? Bool, true)
    }

    static func stringFieldsAreLengthBounded() throws {
        let line = try PerformanceDiagnostics.metricLine(
            event: String(repeating: "e", count: 200),
            fields: ["context": .string(String(repeating: "x", count: 1_000))],
            timestamp: "t"
        )
        let object = try decode(line)
        try expectEqual((object["event"] as? String)?.count, 80)
        try expectEqual((object["context"] as? String)?.count, 256)
    }

    static func fieldCountAndKeysAreLengthBounded() throws {
        var fields: [String: PerformanceMetricValue] = [:]
        for index in 0 ..< 100 {
            fields[String(repeating: "k", count: 100) + String(format: "%03d", index)] = .int(index)
        }
        let object = try decode(PerformanceDiagnostics.metricLine(
            event: "bounded",
            fields: fields,
            timestamp: "t"
        ))
        try expectLessThanOrEqual(object.count, PerformanceDiagnostics.maximumFieldCount + 2)
        for key in object.keys where key != "event" && key != "timestamp" {
            try expectLessThanOrEqual(key.count, PerformanceDiagnostics.maximumFieldKeyLength)
        }
    }

    static func logRotationIsSizeBounded() throws {
        let max = PerformanceDiagnostics.maximumCurrentLogBytes
        try expect(!PerformanceDiagnostics.shouldRotateLog(existingBytes: 0, incomingBytes: max + 1))
        try expect(!PerformanceDiagnostics.shouldRotateLog(existingBytes: max - 10, incomingBytes: 10))
        try expect(PerformanceDiagnostics.shouldRotateLog(existingBytes: max - 10, incomingBytes: 11))
    }
}
