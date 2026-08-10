import CleanroomCore
import Foundation

@main
struct CleanroomSimulatorCLI {
    static func main() async throws {
        if CommandLine.arguments.dropFirst() == ["--example"] {
            let scenario = SimulationScenario(events: [
                .trigger(.running),
                .command(.reconcile),
                .trigger(.stopped),
                .command(.reconcile),
                .advanceTime(seconds: 6),
                .command(.reconcile),
            ])
            try writeJSON(scenario)
            return
        }
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(
                Data("usage: cleanroom-sim SCENARIO.json | cleanroom-sim --example\n".utf8))
            throw CocoaError(.fileReadInvalidFileName)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let scenario = try decoder.decode(
            SimulationScenario.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        )
        let results = await DeterministicSessionSimulator(scenario: scenario).run()
        try writeJSON(results)
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
