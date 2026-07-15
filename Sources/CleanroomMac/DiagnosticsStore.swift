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

public actor DiagnosticsStore {
    private let directoryURL: URL
    private let eventLogURL: URL
    private let heartbeatURL: URL
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
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: eventLogURL.path)
        try truncateIfNeeded()
    }

    public func recentEvents(limit: Int = 50) -> [TransitionReport] {
        guard let data = try? Data(contentsOf: eventLogURL),
            let text = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n")
            .suffix(max(0, limit))
            .compactMap { try? decoder.decode(TransitionReport.self, from: Data($0.utf8)) }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func truncateIfNeeded() throws {
        let attributes = try fileManager.attributesOfItem(atPath: eventLogURL.path)
        guard let size = attributes[.size] as? NSNumber,
            size.intValue > maximumEventBytes,
            let data = try? Data(contentsOf: eventLogURL)
        else { return }
        let keep = data.suffix(maximumEventBytes / 2)
        let start = keep.firstIndex(of: 0x0A).map { keep.index(after: $0) } ?? keep.startIndex
        try Data(keep[start...]).write(to: eventLogURL, options: .atomic)
    }
}
