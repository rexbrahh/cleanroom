import CleanroomCore
import Foundation
import Testing

@testable import CleanroomMac

@Suite("Diagnostics persistence")
struct DiagnosticsStoreTests {
    @Test("malformed event lines remain visible while valid events are returned")
    func malformedLinesAreReported() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticsStore(directoryURL: directory)
        try await store.append(TransitionReport(phase: .idle, message: "valid"))
        let eventLogURL = directory.appendingPathComponent("events.jsonl")
        let handle = try FileHandle(forWritingTo: eventLogURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()

        let result = try await store.recentEvents(limit: 10)

        #expect(result.events.map(\.message) == ["valid"])
        #expect(result.malformedLineCount == 1)
    }

    @Test("invalid event-log encoding is an explicit read failure")
    func invalidEncodingThrows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0xFF, 0x0A]).write(to: directory.appendingPathComponent("events.jsonl"))
        let store = DiagnosticsStore(directoryURL: directory)

        await #expect(throws: DiagnosticsStoreError.self) {
            _ = try await store.recentEvents(limit: 10)
        }
    }

    @Test("performance timeline is bounded and contains no gameplay content")
    func performanceTimelineIsPrivateAndBounded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-performance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticsStore(directoryURL: directory)
        let startedAt = Date(timeIntervalSince1970: 100)
        for index in 0..<3 {
            try await store.appendPerformance(
                SessionPerformanceRecord(
                    operation: "restore-\(index)",
                    startedAt: startedAt,
                    completedAt: startedAt.addingTimeInterval(0.125),
                    thermalState: "nominal",
                    results: [
                        ActionResult(
                            action: "restore",
                            target: "service",
                            outcome: index == 2 ? .failed : .succeeded,
                            detail: "system result",
                            occurredAt: startedAt.addingTimeInterval(0.1)
                        )
                    ]
                ))
        }

        let records = try await store.recentPerformance(limit: 2)

        #expect(records.map(\.operation) == ["restore-1", "restore-2"])
        #expect(records.last?.durationMilliseconds == 125)
        #expect((99...100).contains(records.last?.actions.first?.completedAfterMilliseconds ?? -1))
        #expect(records.last?.failureCount == 1)
        #expect(records.allSatisfy { $0.contentBoundary.contains("no gameplay content") })
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("performance.jsonl").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
