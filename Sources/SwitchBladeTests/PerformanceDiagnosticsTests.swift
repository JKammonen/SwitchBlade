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
        ("PerformanceDiagnostics/logRotation_isSizeBounded", logRotationIsSizeBounded),
        ("PerformanceDiagnostics/largeMRU_roundTripsEveryWindowAndReason", largeMRURoundTripsEveryWindowAndReason),
        ("PerformanceDiagnostics/displayOrder_tracksStaleRefreshAndMinimizedMerge", displayOrderTracksStaleRefreshAndMinimizedMerge),
        ("PerformanceDiagnostics/cacheStabilization_recordsBothOrders", cacheStabilizationRecordsBothOrders)
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

    private final class Recording: @unchecked Sendable {
        let entries = LockedValue<[(String, [String: PerformanceMetricValue])]>([])

        init() {
            let entries = self.entries
            PerformanceDiagnostics.testObserver.value = { event, fields in
                entries.withValue { $0.append((event, fields)) }
            }
        }

        func stop() { PerformanceDiagnostics.testObserver.value = nil }

        func payloads(event: String, context: String? = nil) throws -> [[String: Any]] {
            try entries.value.filter { $0.0 == event }.map { name, fields in
                try decode(PerformanceDiagnostics.metricLine(event: name, fields: fields, timestamp: "test"))
            }.filter { context == nil || $0["context"] as? String == context }
        }
    }

    private static func rows(_ chunks: [[String: Any]]) -> [String] {
        chunks.sorted { ($0["chunk_index"] as? Int ?? 0) < ($1["chunk_index"] as? Int ?? 0) }
            .flatMap { chunk in
                chunk.keys.filter { $0.hasPrefix("row_") && $0 != "row_count" }.sorted()
                    .compactMap { chunk[$0] as? String }
            }
    }

    private static func windowIDs(_ chunks: [[String: Any]]) -> [UInt32] {
        rows(chunks).compactMap { row in
            guard let start = row.range(of: ":id=")?.upperBound else { return nil }
            return UInt32(row[start...].prefix(while: { $0 != "," }))
        }
    }

    @MainActor static func largeMRURoundTripsEveryWindowAndReason() throws {
        let recording = Recording()
        defer { recording.stop() }
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        // Above the observed 25-window desktop AND two chunk boundaries.
        let items: [WindowItem] = (0..<65).map { (index: Int) -> WindowItem in
            let windowID = UInt32(42_000 + index)
            let pid = Int32(60_000 + index)
            return makeItem(id: windowID, pid: pid,
                     appName: "PRIVATE_APP_SENTINEL", title: "PRIVATE_TITLE_SENTINEL",
                     isFrontmostApp: index == 0)
        }
        for item in items { tracker.rememberSelection(item.id, in: items) }
        let ordered = tracker.orderedForDisplay(from: items, context: "large-roundtrip", snapshotDiagnosticID: "snapshot-test")
        let chunks = try recording.payloads(event: "mru_order")
        try expectEqual(chunks.count, 3)
        try expectEqual(windowIDs(chunks), ordered.map(\.id))
        try expectEqual(windowIDs(try recording.payloads(event: "mru_snapshot")), items.map(\.id))
        try expectEqual(Set(chunks.compactMap { $0["event_sequence"] as? Int }).count, 1)
        for chunk in chunks {
            try expectEqual(chunk["chunk_count"] as? Int, 3)
            try expectEqual(chunk["row_count"] as? Int, 65)
            try expectEqual(chunk["correlation_id"] as? String, "snapshot-test")
            try expectLessThanOrEqual(chunk.count, PerformanceDiagnostics.maximumFieldCount + 2)
            let data = try JSONSerialization.data(withJSONObject: chunk)
            let text = String(decoding: data, as: UTF8.self)
            try expect(!text.contains("PRIVATE_"), "order diagnostics must not expose window/app text")
        }
        for row in rows(chunks) {
            try expect(row.contains("reason="))
            try expectLessThanOrEqual(row.count, 256)
        }
        try expect(rows(chunks).last?.contains("reason=rankID:") == true, "tail reason must survive serialization")
    }

    @MainActor static func displayOrderTracksStaleRefreshAndMinimizedMerge() async throws {
        let recording = Recording()
        defer { recording.stop() }
        let (store, catalog, _, _) = makeStore(cachedOpenItemsMaxAge: -1)
        defer { store.cancel() }
        catalog.visibleItems = (0..<28).map { (index: Int) -> WindowItem in
            let windowID = UInt32(43_000 + index)
            let pid = Int32(61_000 + index)
            return makeItem(id: windowID, pid: pid, isFrontmostApp: index == 0)
        }
        await seedOpenItemsCache(store)
        recording.entries.value = []
        let newWindow = makeItem(id: 44_000, pid: 62_000)
        catalog.visibleItems.append(newWindow)
        catalog.minimizedItems = [makeItem(id: 45_000, pid: 63_000, isMinimized: true)]
        catalog.minimizedSnapshotDelayNanoseconds = 100_000_000
        store.requestCycle(forward: true)
        for _ in 0..<100 where !store.items.contains(where: { $0.id == 45_000 }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(store.isVisible)
        let stale = try recording.payloads(event: "display_order", context: "stale-cache-refresh")
        try expect(!stale.isEmpty, "fresh replacement of the displayed stale cache must be logged")
        try expect(windowIDs(stale).contains(44_000))
        let merged = try recording.payloads(event: "display_order", context: "minimized-merge")
        try expectEqual(windowIDs(merged), store.items.map(\.id))
        try expectEqual(merged.last?["selected_id"] as? Int, Int(store.selectedID ?? 0))
        try expectEqual(merged.last?["row_count"] as? Int, 30)
        try expect(!recording.payloads(event: "display_order", context: "panel-show").isEmpty)
        let sequences = try recording.payloads(event: "display_order").compactMap { $0["event_sequence"] as? Int }
        try expectEqual(sequences, sequences.sorted())
    }

    @MainActor static func cacheStabilizationRecordsBothOrders() async throws {
        let recording = Recording()
        defer { recording.stop() }
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let (store, catalog, _, _) = makeStore(mruTracker: tracker, initialFrontmostAppPID: 100)
        defer { store.cancel() }
        catalog.visibleItems = [
            makeItem(id: 10, pid: 100, isFrontmostApp: true),
            makeItem(id: 11, pid: 100, isFrontmostApp: true),
            makeItem(id: 20, pid: 200),
            makeItem(id: 30, pid: 300)
        ]
        await seedOpenItemsCache(store)
        // History changes while the cached order remains fixed. The real
        // multi-window open must report both sides of that disagreement.
        tracker.rememberSelection(20, in: catalog.visibleItems)
        tracker.rememberSelection(30, in: catalog.visibleItems)
        await openSwitcher(store)
        let changes = try recording.payloads(event: "cache_stabilization")
        let before = changes.filter { $0["phase"] as? String == "before" }
        let after = changes.filter { $0["phase"] as? String == "after" }
        try expect(!before.isEmpty, "the production cache stabilization must emit its input and output")
        try expectEqual(before.count, after.count)
        try expectEqual(before.last?["correlation_id"] as? String, after.last?["correlation_id"] as? String)
        try expect(windowIDs(before) != windowIDs(after))
        let decisions = try recording.payloads(event: "focus_rank_decision", context: "switcher-open-focus")
        let returned = try recording.payloads(event: "snapshot_returned")
        try expectNotNil(decisions.last?["correlation_id"])
        try expectEqual(decisions.last?["correlation_id"] as? String, returned.last?["correlation_id"] as? String)
    }
}
