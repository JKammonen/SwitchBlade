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
