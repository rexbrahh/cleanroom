import CleanroomMac
import CleanroomProtocol
import Foundation

@main
struct CleanroomAgentMain {
    static func main() async {
        let controller = MacSystemController.live()
        let runtime = AgentRuntime(controller: controller)
        await runtime.startMonitoring()
        let host = AgentHost(runtime: runtime)
        await host.run()
    }
}
