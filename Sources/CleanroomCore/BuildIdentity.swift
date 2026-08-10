import Foundation

public struct CleanroomBuildIdentity: Codable, Sendable, Equatable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    public var description: String { "\(version) (\(build))" }

    public static var current: Self {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        {
            return Self(version: version, build: build)
        }

        let executableURLs = [
            Bundle.main.executableURL,
            CommandLine.arguments.first.map { URL(fileURLWithPath: $0) },
        ].compactMap { $0 }
        for executableURL in executableURLs {
            if let identity = enclosingApplicationIdentity(for: executableURL) {
                return identity
            }
        }
        return Self(version: "development", build: "local")
    }

    public static func applicationIdentity(at applicationURL: URL) -> Self? {
        guard
            let dictionary = NSDictionary(
                contentsOf: applicationURL.appendingPathComponent("Contents/Info.plist")
            ),
            let version = dictionary["CFBundleShortVersionString"] as? String,
            let build = dictionary["CFBundleVersion"] as? String
        else { return nil }
        return Self(version: version, build: build)
    }

    private static func enclosingApplicationIdentity(for executableURL: URL) -> Self? {
        var candidate = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return applicationIdentity(at: candidate)
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}
