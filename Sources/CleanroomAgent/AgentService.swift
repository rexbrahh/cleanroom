import CleanroomProtocol
import Foundation
import OSLog

final class AgentService: NSObject, CleanroomAgentXPC {
    private let runtime: AgentRuntime
    private let logger = Logger(subsystem: "com.rex.cleanroom", category: "xpc")

    init(runtime: AgentRuntime) {
        self.runtime = runtime
    }

    func perform(_ requestData: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        let runtime = runtime
        let logger = logger
        Task {
            let response: AgentResponse
            do {
                let request = try AgentCodec.decode(AgentRequest.self, from: requestData)
                response = await runtime.handle(request)
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

    init(service: AgentService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard connection.processIdentifier > 0 else { return false }
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
