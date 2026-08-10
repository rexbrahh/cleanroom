import CleanroomCore
import Foundation
import Testing

@testable import CleanroomMac

@Suite("Support bundle archive")
struct SupportBundleArchiveTests {
    @Test("writes a verified local-only 0600 zip")
    func archiveIsLocalAndBounded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-support-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("support.zip")
        let document = SupportBundleRedactor.makeDocument(
            appVersion: "test",
            status: nil,
            preflight: nil,
            events: [],
            receipts: [],
            performance: []
        )

        try await SupportBundleArchive.write(document, to: destination)

        let data = try Data(contentsOf: destination)
        #expect(data.prefix(2) == Data([0x50, 0x4B]))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
