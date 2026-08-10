import CleanroomProtocol
import Darwin
import Foundation
import OSLog
import Security

struct AgentClientIdentity: Equatable {
    let effectiveUserIdentifier: uid_t
    let signingIdentifier: String
    let teamIdentifier: String?
    let executableURL: URL
    let signatureIsValid: Bool
}

struct AgentClientAuthorizationPolicy {
    static let allowedSigningIdentifiers: Set<String> = [
        "com.rex.cleanroom",
        "com.rex.cleanroom.cli",
    ]

    let effectiveUserIdentifier: uid_t
    let teamIdentifier: String?
    let adHocExecutableURLs: Set<URL>

    func permits(_ identity: AgentClientIdentity) -> Bool {
        guard identity.effectiveUserIdentifier == effectiveUserIdentifier,
            identity.signatureIsValid,
            Self.allowedSigningIdentifiers.contains(identity.signingIdentifier)
        else { return false }

        if let teamIdentifier {
            return identity.teamIdentifier == teamIdentifier
        }
        return identity.teamIdentifier == nil
            && adHocExecutableURLs.contains(identity.executableURL.standardizedFileURL)
    }
}

enum AgentRequestDecoder {
    static let maximumEncodedBytes = 64 * 1_024

    static func decode(_ requestData: Data) throws -> AgentRequest {
        guard requestData.count <= maximumEncodedBytes else {
            throw AgentProtocolError.requestTooLarge(maximumEncodedBytes)
        }
        return try AgentCodec.decode(AgentRequest.self, from: requestData)
    }
}

actor AgentRequestRegistry {
    private enum Entry {
        case inProgress(request: AgentRequest, task: Task<AgentResponse, Never>)
        case completed(request: AgentRequest, response: AgentResponse)
    }

    private var entries: [UUID: Entry] = [:]
    private let maximumCompletedRequests: Int

    init(maximumCompletedRequests: Int = 200) {
        self.maximumCompletedRequests = maximumCompletedRequests
    }

    func response(
        for request: AgentRequest,
        operation: @escaping @Sendable () async -> AgentResponse
    ) async -> AgentResponse {
        if let entry = entries[request.identifier] {
            switch entry {
            case .inProgress(let original, _):
                return original == request
                    ? AgentResponse(requestIdentifier: request.identifier, payload: .requestInProgress)
                    : collisionResponse(for: request)
            case .completed(let original, let response):
                return original == request ? response : collisionResponse(for: request)
            }
        }

        let task = Task { await operation() }
        entries[request.identifier] = .inProgress(request: request, task: task)
        let response = await task.value
        entries[request.identifier] = .completed(request: request, response: response)
        pruneCompletedRequests()
        return response
    }

    private func collisionResponse(for request: AgentRequest) -> AgentResponse {
        AgentResponse(
            requestIdentifier: request.identifier,
            payload: .failure("The request identifier was already used for a different command.")
        )
    }

    private func pruneCompletedRequests() {
        let completedIdentifiers = entries.compactMap { identifier, entry in
            if case .completed = entry { return identifier }
            return nil
        }
        guard completedIdentifiers.count > maximumCompletedRequests else { return }
        for identifier in completedIdentifiers.prefix(
            completedIdentifiers.count - maximumCompletedRequests
        ) {
            entries.removeValue(forKey: identifier)
        }
    }
}

private struct AgentConnectionAuthorizer {
    private let policy: AgentClientAuthorizationPolicy?

    init() {
        guard let ownIdentity = Self.identity(forCode: Self.currentCode(), effectiveUserIdentifier: geteuid())
        else {
            policy = nil
            return
        }
        let appURL = Self.enclosingApplicationURL(for: ownIdentity.executableURL)
        let allowedURLs: Set<URL>
        if let appURL {
            allowedURLs = [
                appURL.appendingPathComponent("Contents/MacOS/Cleanroom").standardizedFileURL,
                appURL.appendingPathComponent("Contents/Resources/cleanroomctl").standardizedFileURL,
            ]
        } else {
            allowedURLs = []
        }
        policy = AgentClientAuthorizationPolicy(
            effectiveUserIdentifier: geteuid(),
            teamIdentifier: ownIdentity.teamIdentifier,
            adHocExecutableURLs: allowedURLs
        )
    }

    func permits(_ connection: NSXPCConnection) -> Bool {
        guard connection.processIdentifier > 0,
            connection.effectiveUserIdentifier == geteuid(),
            let policy,
            let identity = Self.identity(
                forCode: Self.code(for: connection.processIdentifier),
                effectiveUserIdentifier: connection.effectiveUserIdentifier
            )
        else { return false }
        return policy.permits(identity)
    }

    private static func currentCode() -> SecCode? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess else { return nil }
        return code
    }

    private static func code(for processIdentifier: pid_t) -> SecCode? {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)] as CFDictionary
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess
        else { return nil }
        return code
    }

    private static func identity(
        forCode code: SecCode?,
        effectiveUserIdentifier: uid_t
    ) -> AgentClientIdentity? {
        guard let code else { return nil }
        let validity = SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard
            SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
            let staticCode,
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
            ) == errSecSuccess,
            let dictionary = information as? [String: Any],
            let signingIdentifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
            let executableURL = dictionary[kSecCodeInfoMainExecutable as String] as? URL
        else { return nil }
        return AgentClientIdentity(
            effectiveUserIdentifier: effectiveUserIdentifier,
            signingIdentifier: signingIdentifier,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            executableURL: executableURL.standardizedFileURL,
            signatureIsValid: validity == errSecSuccess
        )
    }

    private static func enclosingApplicationURL(for executableURL: URL) -> URL? {
        var candidate = executableURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate.standardizedFileURL }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}

final class AgentService: NSObject, CleanroomAgentXPC {
    private let runtime: AgentRuntime
    private let requests = AgentRequestRegistry()
    private let logger = Logger(subsystem: "com.rex.cleanroom", category: "xpc")

    init(runtime: AgentRuntime) {
        self.runtime = runtime
    }

    func perform(_ requestData: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        let runtime = runtime
        let requests = requests
        let logger = logger
        Task {
            let response: AgentResponse
            do {
                let request = try AgentRequestDecoder.decode(requestData)
                response = await requests.response(for: request) {
                    await runtime.handle(request)
                }
            } catch {
                logger.error("Invalid request: \(error.localizedDescription, privacy: .public)")
                response = AgentResponse(
                    requestIdentifier: UUID(),
                    payload: .failure("Invalid agent request: \(error.localizedDescription)")
                )
            }
            let data = (try? AgentCodec.encode(response)) ?? Data()
            reply(data)
        }
    }
}

final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: AgentService
    private let authorizer = AgentConnectionAuthorizer()
    private let logger = Logger(subsystem: "com.rex.cleanroom", category: "xpc-auth")

    init(service: AgentService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard authorizer.permits(connection) else {
            logger.error("Rejected unauthorized XPC client PID \(connection.processIdentifier, privacy: .public)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: CleanroomAgentXPC.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

final class AgentHost {
    private let listener: NSXPCListener
    private let delegate: AgentListenerDelegate

    init(runtime: AgentRuntime) {
        let service = AgentService(runtime: runtime)
        self.delegate = AgentListenerDelegate(service: service)
        self.listener = NSXPCListener(machServiceName: cleanroomAgentMachServiceName)
        self.listener.delegate = delegate
    }

    func run() async {
        listener.resume()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3_600))
        }
    }
}
