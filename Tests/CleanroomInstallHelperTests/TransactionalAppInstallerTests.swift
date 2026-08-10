import Foundation
import Testing

@testable import CleanroomInstallHelper

@Suite("Transactional app installer")
struct TransactionalAppInstallerTests {
    @Test("existing and staged apps swap atomically")
    func atomicSwap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Cleanroom.app")
        let stagingDirectory = directory.appendingPathComponent("staging")
        let staged = stagingDirectory.appendingPathComponent("Cleanroom.app")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("version"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("version"))

        try TransactionalAppInstaller.swap(stagedURL: staged, destinationURL: destination)

        #expect(try String(contentsOf: destination.appendingPathComponent("version"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: staged.appendingPathComponent("version"), encoding: .utf8) == "old")

        try TransactionalAppInstaller.swap(stagedURL: staged, destinationURL: destination)

        #expect(try String(contentsOf: destination.appendingPathComponent("version"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: staged.appendingPathComponent("version"), encoding: .utf8) == "new")
    }

    @Test("a failed swap leaves the installed app untouched")
    func failedSwapPreservesDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Cleanroom.app")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("version")
        try Data("old".utf8).write(to: marker)

        #expect(throws: (any Error).self) {
            try TransactionalAppInstaller.swap(
                stagedURL: directory.appendingPathComponent("missing.app"),
                destinationURL: destination
            )
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "old")
    }
}
