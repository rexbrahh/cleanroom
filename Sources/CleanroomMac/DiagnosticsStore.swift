import CleanroomCore
import Foundation

public struct AgentHeartbeat: Codable, Sendable, Equatable {
    public let processIdentifier: Int32
    public let startedAt: Date
    public let updatedAt: Date
    public let phase: CleanroomPhase
    public let message: String

    public init(
        processIdentifier: Int32,
        startedAt: Date,
        updatedAt: Date,
        phase: CleanroomPhase,
        message: String
    ) {
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.phase = phase
        self.message = message
    }
}

public struct DiagnosticsReadResult: Sendable, Equatable {
    public let events: [TransitionReport]
    public let malformedLineCount: Int

    public init(events: [TransitionReport], malformedLineCount: Int) {
        self.events = events
        self.malformedLineCount = malformedLineCount
    }
}

public enum DiagnosticsStoreError: Error, LocalizedError {
    case invalidEventLogEncoding

    public var errorDescription: String? {
        "The diagnostic event log is not valid UTF-8."
    }
}

public actor DiagnosticsStore {
    private let directoryURL: URL
    private let eventLogURL: URL
    private let heartbeatURL: URL
    private let performanceURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let maximumEventBytes: Int

    public init(
        directoryURL: URL = CleanroomPaths.applicationSupportDirectory,
        maximumEventBytes: Int = 512 * 1024,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.eventLogURL = directoryURL.appendingPathComponent("events.jsonl")
        self.heartbeatURL = directoryURL.appendingPathComponent("heartbeat.json")
        self.performanceURL = directoryURL.appendingPathComponent("performance.jsonl")
        self.maximumEventBytes = maximumEventBytes
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func writeHeartbeat(_ heartbeat: AgentHeartbeat) throws {
        try ensureDirectory()
        let data = try encoder.encode(heartbeat)
        try data.write(to: heartbeatURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: heartbeatURL.path)
    }

    public func append(_ report: TransitionReport) throws {
        try ensureDirectory()
        var data = try encoder.encode(report)
        data.append(0x0A)
        if !fileManager.fileExists(atPath: eventLogURL.path) {
            try data.write(to: eventLogURL, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: eventLogURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: eventLogURL.path)
        try truncateIfNeeded(eventLogURL)
    }

    public func appendPerformance(_ record: SessionPerformanceRecord) throws {
        try ensureDirectory()
        var data = try encoder.encode(record)
        data.append(0x0A)
        if !fileManager.fileExists(atPath: performanceURL.path) {
            try data.write(to: performanceURL, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: performanceURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: performanceURL.path)
        try truncateIfNeeded(performanceURL)
    }

    public func recentPerformance(limit: Int = 30) throws -> [SessionPerformanceRecord] {
        guard fileManager.fileExists(atPath: performanceURL.path) else { return [] }
        let data = try Data(contentsOf: performanceURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DiagnosticsStoreError.invalidEventLogEncoding
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try text.split(separator: "\n").suffix(max(0, limit)).map {
            try decoder.decode(SessionPerformanceRecord.self, from: Data($0.utf8))
        }
    }

    /// Reads only the tail of the log. The full file is capped at 512 KiB,
    /// but transition events with complete results can be tens of KB each, so
    /// a generous window keeps every caller's limit satisfiable while avoiding
    /// a whole-file read and split on every poll.
    public func recentEvents(limit: Int = 50) throws -> DiagnosticsReadResult {
        guard fileManager.fileExists(atPath: eventLogURL.path) else {
            return DiagnosticsReadResult(events: [], malformedLineCount: 0)
        }
        let handle = try FileHandle(forReadingFrom: eventLogURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return DiagnosticsReadResult(events: [], malformedLineCount: 0) }

        let window: UInt64 = 256 * 1024
        let offset = size > window ? size - window : 0
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()
        if offset > 0, let firstNewline = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: firstNewline)...]
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw DiagnosticsStoreError.invalidEventLogEncoding
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = text.split(separator: "\n").suffix(max(0, limit))
        var events: [TransitionReport] = []
        var malformedLineCount = 0
        for line in lines {
            do {
                events.append(try decoder.decode(TransitionReport.self, from: Data(line.utf8)))
            } catch {
                malformedLineCount += 1
            }
        }
        return DiagnosticsReadResult(events: events, malformedLineCount: malformedLineCount)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func truncateIfNeeded(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
            size.intValue > maximumEventBytes
        else { return }
        let data = try Data(contentsOf: url)
        let keep = data.suffix(maximumEventBytes / 2)
        let start = keep.firstIndex(of: 0x0A).map { keep.index(after: $0) } ?? keep.startIndex
        try Data(keep[start...]).write(to: url, options: .atomic)
    }
}
