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
            return String(value.prefix(256))
        }
    }
}

enum PerformanceDiagnostics {
    @TaskLocal static var correlationID: String?
    @TaskLocal static var context: String = "unknown"
    private static let sessionID = UUID().uuidString
    private static let sequence = LockedValue(0)
    static let maximumRowsPerChunk = 32
    #if DEBUG
    // Observe the actual producer payloads without disk IO or signed-app TCC.
    static let testObserver = LockedValue<(@Sendable (String, [String: PerformanceMetricValue]) -> Void)?>(nil)
    #endif
    static let fileURL = PerformanceMetricWriter.defaultFileURL
    static let maximumCurrentLogBytes = 5 * 1_024 * 1_024
    static let maximumFieldCount = 64
    static let maximumFieldKeyLength = 80
    static let maximumPendingWrites = 128
    private static let pendingWrites = LockedValue(0)

    static func shouldRotateLog(existingBytes: Int, incomingBytes: Int) -> Bool {
        existingBytes > 0 && existingBytes + incomingBytes > maximumCurrentLogBytes
    }

    static func record(_ event: String, fields: [String: PerformanceMetricValue]) {
        recordBatch(event, chunks: [fields])
    }

    /// Each window gets its own bounded field. Never concatenate an entire
    /// order into one 256-character string. Chunks are admitted as one batch;
    /// count/index metadata makes rotation or a partial write detectable.
    static func rowChunks(fields: [String: PerformanceMetricValue], rows: [String]) -> [[String: PerformanceMetricValue]] {
        let count = max(1, (rows.count + maximumRowsPerChunk - 1) / maximumRowsPerChunk)
        return (0..<count).map { chunk in
            var result = fields
            result["chunk_index"] = .int(chunk)
            result["chunk_count"] = .int(count)
            result["row_count"] = .int(rows.count)
            let start = chunk * maximumRowsPerChunk
            let end = min(rows.count, start + maximumRowsPerChunk)
            for index in start..<end {
                result[String(format: "row_%06d", index)] = .string(rows[index])
            }
            return result
        }
    }

    static func recordRows(_ event: String, fields: [String: PerformanceMetricValue], rows: [String]) {
        guard isEnabled else { return }
        recordBatch(event, chunks: rowChunks(fields: fields, rows: rows))
    }

    static var isEnabled: Bool {
        #if DEBUG
        if testObserver.value != nil { return true }
        #endif
        return PerformanceLoggingState.mode == .debug && Bundle.main.bundleURL.pathExtension == "app"
    }

    private static func recordBatch(_ event: String, chunks: [[String: PerformanceMetricValue]]) {
        guard isEnabled else { return }
        let eventSequence = sequence.withValue { value in value += 1; return value }
        let emittedAt = ProcessInfo.processInfo.systemUptime * 1_000
        let payloads = chunks.map { fields in
            var payload = fields
            payload["session_id"] = .string(sessionID)
            payload["event_sequence"] = .int(eventSequence)
            payload["emitted_uptime_ms"] = .double(emittedAt)
            payload["diagnostic_context"] = .string(context)
            if let correlationID { payload["correlation_id"] = .string(correlationID) }
            return payload
        }
        #if DEBUG
        if let observer = testObserver.value {
            for payload in payloads { observer(event, payload) }
            return
        }
        #endif
        guard PerformanceLoggingState.mode == .debug else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let accepted = pendingWrites.withValue { pending -> Bool in
            guard pending < maximumPendingWrites else { return false }
            pending += 1
            return true
        }
        guard accepted else { return }

        Task.detached(priority: .utility) {
            defer { pendingWrites.withValue { $0 -= 1 } }
            for payload in payloads {
                await PerformanceMetricWriter.shared.record(event: event, fields: payload)
            }
        }
    }

    static func recordWindowOrder(_ event: String, items: [WindowItem], fields: [String: PerformanceMetricValue]) {
        guard isEnabled else { return }
        let rows = items.enumerated().map { index, item in
            "\(index):id=\(item.id),pid=\(item.pid),window_pid=\(item.windowProcessIdentifier),front=\(item.isFrontmostApp ? 1 : 0),minimized=\(item.isMinimized ? 1 : 0)"
        }
        recordRows(event, fields: fields, rows: rows)
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
            "event": String(event.prefix(80))
        ]
        for key in fields.keys.sorted().prefix(maximumFieldCount) {
            payload[String(key.prefix(maximumFieldKeyLength))] = fields[key]?.jsonValue
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

            let fileManager = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let directoryAttributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            if fileManager.fileExists(atPath: fileURL.path) {
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                let existingBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
                if PerformanceDiagnostics.shouldRotateLog(
                    existingBytes: existingBytes,
                    incomingBytes: line.count
                ) {
                    let previousURL = fileURL.appendingPathExtension("previous")
                    if fileManager.fileExists(atPath: previousURL.path) {
                        try fileManager.removeItem(at: previousURL)
                    }
                    try fileManager.moveItem(at: fileURL, to: previousURL)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previousURL.path)
                }
            }

            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                guard fileManager.createFile(
                    atPath: fileURL.path,
                    contents: line,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        } catch {
            Logger.switcher.error("Performance metric write failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
