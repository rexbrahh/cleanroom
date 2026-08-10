import Foundation

public let cleanroomAgentMachServiceName = "com.rex.cleanroom.agent"

@objc public protocol CleanroomAgentXPC {
    func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

public actor CleanroomAgentClient {
    private var connection: NSXPCConnection?
    private var negotiatedCapabilities: Set<AgentCapability> = []

    public init() {}

    public func send(
        _ command: AgentCommand,
        destructiveRecoveryConfirmed: Bool = false
    ) async throws -> AgentResponse {
        let request = AgentRequest(
            command: command,
            destructiveRecoveryConfirmed: destructiveRecoveryConfirmed
        )
        do {
            return try await send(request)
        } catch AgentProtocolError.timedOut {
            invalidate()
            return try await send(request)
        }
    }

    /// Retrying an explicit request preserves its identity, allowing the
    /// agent to return in-progress or cached completion state without running
    /// the command twice.
    public func send(_ request: AgentRequest) async throws -> AgentResponse {
        if let required = request.command.requiredCapability {
            try await ensureCapability(required)
        }
        return try await sendWithoutNegotiation(request)
    }

    private func ensureCapability(_ required: AgentCapability) async throws {
        if negotiatedCapabilities.contains(required) { return }
        let request = AgentRequest(
            command: .handshake(AgentHandshakeRequest(requiredCapabilities: [required]))
        )
        let response: AgentResponse
        do {
            response = try await sendWithoutNegotiation(request)
        } catch {
            throw AgentProtocolError.incompatible(
                "Capability handshake failed before \(required.rawValue): \(error.localizedDescription)"
            )
        }
        guard case .handshake(let handshake) = response.payload else {
            throw AgentProtocolError.incompatible("The agent did not return a capability handshake.")
        }
        try handshake.validate(required: required)
        negotiatedCapabilities = Set(handshake.capabilities)
    }

    private func sendWithoutNegotiation(_ request: AgentRequest) async throws -> AgentResponse {
        let requestData = try AgentCodec.encode(request)
        let connection = activeConnection()

        do {
            let responseData: Data = try await withCheckedThrowingContinuation { continuation in
                let gate = ContinuationGate(continuation)
                gate.armTimeout(after: Self.timeout(for: request.command))
                guard
                    let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                        gate.fail(error)
                    }) as? CleanroomAgentXPC
                else {
                    gate.fail(AgentProtocolError.invalidResponse)
                    return
                }
                proxy.perform(requestData) { data in
                    gate.succeed(data)
                }
            }

            let response = try AgentCodec.decode(AgentResponse.self, from: responseData)
            guard response.requestIdentifier == request.identifier else {
                throw AgentProtocolError.requestMismatch
            }
            if case .failure(let message) = response.payload {
                throw AgentProtocolError.remoteFailure(message)
            }
            return response
        } catch {
            // A wedged endpoint (e.g. launchd holds the Mach service while the
            // agent cannot spawn) must not poison future sends: the next call
            // gets a fresh connection.
            if case AgentProtocolError.timedOut = error {
                invalidate()
            }
            throw error
        }
    }

    /// Bounded waits keep UI polling and the CLI responsive when the agent is
    /// unreachable; transitions get generous budgets because they run
    /// preflight, termination grace periods, and restore verification.
    private static func timeout(for command: AgentCommand) -> TimeInterval {
        switch command {
        case .enter, .restore, .safeLaunch, .preflight, .recover, .migrateLegacy:
            60
        case .handshake, .status, .reconcile, .setPaused, .setIncidentMode, .recentEvents,
            .performanceTimeline, .recoveryReceipts, .profiles, .selectProfile, .networkLatency:
            15
        case .systemPressure:
            15
        case .validateProfile, .saveProfile:
            30
        case .deviceCalibration, .saveDeviceCalibration:
            15
        case .exportProfile, .previewProfileImport:
            15
        }
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
        negotiatedCapabilities = []
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let created = NSXPCConnection(
            machServiceName: cleanroomAgentMachServiceName,
            options: []
        )
        created.remoteObjectInterface = NSXPCInterface(with: CleanroomAgentXPC.self)
        created.invalidationHandler = {}
        created.interruptionHandler = {}
        created.resume()
        connection = created
        return created
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func succeed(_ data: Data) {
        take()?.resume(returning: data)
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    func armTimeout(after seconds: TimeInterval) {
        let task = Task { [self] in
            try? await Task.sleep(for: .seconds(seconds))
            fail(AgentProtocolError.timedOut)
        }
        lock.lock()
        timeoutTask = task
        lock.unlock()
    }

    private func take() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        timeoutTask?.cancel()
        timeoutTask = nil
        let value = continuation
        continuation = nil
        return value
    }
}
