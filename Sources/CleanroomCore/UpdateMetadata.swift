import CryptoKit
import Foundation

public enum CleanroomUpdateChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case beta
}

public struct CleanroomUpdateManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let channel: CleanroomUpdateChannel
    public let version: String
    public let build: String
    public let archiveURL: URL
    public let sha256: String
    public let minimumSystemVersion: String
    public let publishedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        channel: CleanroomUpdateChannel,
        version: String,
        build: String,
        archiveURL: URL,
        sha256: String,
        minimumSystemVersion: String = "15.0",
        publishedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.channel = channel
        self.version = version
        self.build = build
        self.archiveURL = archiveURL
        self.sha256 = sha256.lowercased()
        self.minimumSystemVersion = minimumSystemVersion
        self.publishedAt = publishedAt
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CleanroomUpdateError.invalidManifest("unsupported schema \(schemaVersion)")
        }
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
            build.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil
        else { throw CleanroomUpdateError.invalidManifest("invalid version or build") }
        guard archiveURL.scheme == "https" else {
            throw CleanroomUpdateError.invalidManifest("archive URL must use HTTPS")
        }
        guard sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw CleanroomUpdateError.invalidManifest("invalid SHA-256")
        }
    }

    public func verify(archive: Data) throws {
        try validate()
        let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard actual == sha256 else { throw CleanroomUpdateError.checksumMismatch }
    }
}

public enum CleanroomUpdateError: Error, Equatable, LocalizedError, Sendable {
    case invalidManifest(String)
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let detail): "Invalid update manifest: \(detail)."
        case .checksumMismatch: "The update archive SHA-256 does not match its manifest."
        }
    }
}
