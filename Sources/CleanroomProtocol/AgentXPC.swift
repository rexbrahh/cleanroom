import Foundation

public let cleanroomAgentMachServiceName = "com.rex.cleanroom.agent"

@objc public protocol CleanroomAgentXPC {
    func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

public actor CleanroomAgentClient {
    private var connection: NSXPCConnection?

    public init() {}

    public func send(_ command: AgentCommand) async throws -> AgentResponse {
        let request = AgentRequest(command: command)
        let requestData = try AgentCodec.encode(request)
        let connection = activeConnection()

        do {
            let responseData: Data = try await withCheckedThrowingContinuation { continuation in
                let gate = ContinuationGate(continuation)
                gate.armTimeout(after: Self.timeout(for: command))
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
        case .enter, .restore, .preflight, .recover, .migrateLegacy:
            60
        case .status, .reconcile, .setPaused, .recentEvents:
            15
        }
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
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
        Task { [self] in
            try? await Task.sleep(for: .seconds(seconds))
            fail(AgentProtocolError.timedOut)
        }
    }

    private func take() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
