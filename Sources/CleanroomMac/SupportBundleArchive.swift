import CleanroomCore
import Foundation

public enum SupportBundleArchiveError: Error, LocalizedError {
    case invalidDestination
    case archiveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDestination: "The support bundle destination must be an exact .zip path."
        case .archiveFailed(let detail): "Support bundle archive failed: \(detail)"
        }
    }
}

public enum SupportBundleArchive {
    public static func write(_ document: SupportBundleDocument, to destination: URL) async throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "zip" else {
            throw SupportBundleArchiveError.invalidDestination
        }
        let fileManager = FileManager.default
        let temporaryParent = fileManager.temporaryDirectory
            .appendingPathComponent("cleanroom-support-\(UUID().uuidString)")
        let bundleDirectory = temporaryParent.appendingPathComponent("Cleanroom-support")
        defer { try? fileManager.removeItem(at: temporaryParent) }
        try fileManager.createDirectory(
            at: bundleDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for (name, data) in [
            ("manifest.json", try encoder.encode(document.manifest)),
            ("evidence.json", try encoder.encode(document.evidence)),
        ] {
            let url = bundleDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let archive = await LocalCommandRunner().run(
            "/usr/bin/ditto",
            arguments: ["-c", "-k", "--keepParent", bundleDirectory.path, destination.path],
            timeout: 10
        )
        guard archive.succeeded else {
            throw SupportBundleArchiveError.archiveFailed(
                archive.launchError ?? archive.standardError)
        }
        let verification = await LocalCommandRunner().run(
            "/usr/bin/unzip", arguments: ["-tq", destination.path], timeout: 10)
        guard verification.succeeded else {
            throw SupportBundleArchiveError.archiveFailed(verification.standardError)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
