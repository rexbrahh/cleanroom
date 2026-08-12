import CryptoKit
import Foundation
import Testing

@testable import CleanroomCore

@Suite("Update metadata")
struct UpdateMetadataTests {
    @Test("stable and beta manifests verify exact archive checksums")
    func checksumAndChannels() throws {
        let archive = Data("signed archive".utf8)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        for channel in CleanroomUpdateChannel.allCases {
            let manifest = CleanroomUpdateManifest(
                channel: channel,
                version: "3.1.0",
                build: "5",
                archiveURL: URL(string: "https://example.com/Cleanroom.zip")!,
                sha256: digest
            )
            try manifest.verify(archive: archive)
            #expect(manifest.channel == channel)
            #expect(manifest.minimumSystemVersion == "15.0")
            #expect(throws: CleanroomUpdateError.checksumMismatch) {
                try manifest.verify(archive: Data("tampered".utf8))
            }
        }
    }

    @Test("unsafe or malformed manifests fail closed")
    func invalidManifest() {
        let manifest = CleanroomUpdateManifest(
            channel: .stable,
            version: "next",
            build: "0",
            archiveURL: URL(string: "http://example.com/Cleanroom.zip")!,
            sha256: "bad"
        )
        #expect(throws: CleanroomUpdateError.self) { try manifest.validate() }
    }
}
