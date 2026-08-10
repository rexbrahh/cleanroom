import Foundation
import Testing

@testable import CleanroomCore

@Suite("Build identity")
struct BuildIdentityTests {
    @Test("application metadata is the version source")
    func readsApplicationInfo() throws {
        let application = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cleanroom-build-\(UUID().uuidString).app")
        let contents = application.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: application) }
        let info: NSDictionary = [
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleVersion": "654",
        ]
        #expect(info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true))

        #expect(
            CleanroomBuildIdentity.applicationIdentity(at: application)
                == CleanroomBuildIdentity(version: "9.8.7", build: "654")
        )
    }
}
