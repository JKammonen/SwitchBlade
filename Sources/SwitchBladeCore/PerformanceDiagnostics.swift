import Foundation
import os.log

enum PerformanceMetricValue: Sendable {
    case bool(Bool)
    case double(Double)
    case int(Int)
    case string(String)

    var jsonValue: Any {
        switch self {
        case .bool(let value):
            return value
        case .double(let value):
            return value
        case .int(let value):
            return value
        case .string(let value):
            return value
        }
    }
}

enum PerformanceDiagnostics {
    static let fileURL = PerformanceMetricWriter.defaultFileURL

    static func record(_ event: String, fields: [String: PerformanceMetricValue]) {
        guard PerformanceLoggingState.mode == .debug else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        Task.detached(priority: .utility) {
            await PerformanceMetricWriter.shared.record(event: event, fields: fields)
        }
    }

    /// Builds the JSON object for one metric event. Pure + side-effect free so
    /// it can be unit tested without touching the filesystem.
    static func metricPayload(
        event: String,
        fields: [String: PerformanceMetricValue],
        timestamp: String
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "timestamp": timestamp,
            "event": event
        ]
        for (key, value) in fields {
            payload[key] = value.jsonValue
        }
        return payload
    }

    /// Serializes one metric event to a single JSONL line (sorted keys +
    /// trailing newline), exactly as written to disk. Pure — no IO.
    static func metricLine(
        event: String,
        fields: [String: PerformanceMetricValue],
        timestamp: String
    ) throws -> Data {
        let payload = metricPayload(event: event, fields: fields, timestamp: timestamp)
        var line = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        line.append(0x0A)
        return line
    }
}

private actor PerformanceMetricWriter {
    static let shared = PerformanceMetricWriter()

    static let defaultFileURL: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("SwitchBlade", isDirectory: true)
            .appendingPathComponent("performance.jsonl")
    }()

    private let fileURL: URL
    private let dateFormatter = ISO8601DateFormatter()

    init(fileURL: URL = PerformanceMetricWriter.defaultFileURL) {
        self.fileURL = fileURL
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func record(event: String, fields: [String: PerformanceMetricValue]) async {
        do {
            let line = try PerformanceDiagnostics.metricLine(
                event: event,
                fields: fields,
                timestamp: dateFormatter.string(from: Date())
            )

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        } catch {
            Logger.switcher.error("Performance metric write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
