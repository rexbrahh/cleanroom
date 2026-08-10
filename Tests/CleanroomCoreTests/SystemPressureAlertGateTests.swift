import CleanroomCore
import Testing

@Suite("System pressure alert gate")
struct SystemPressureAlertGateTests {
    @Test("alerts fire only on configured threshold crossings")
    func crossingsDoNotSpamSteadyState() {
        var gate = SystemPressureAlertGate()
        let thresholds = SystemAlertThresholds(thermal: .serious, batteryPercent: 20)

        #expect(
            gate.crossings(
                for: SystemPressureSample(thermal: .nominal, batteryPercent: 50, onACPower: false),
                thresholds: thresholds
            ).isEmpty)
        #expect(
            gate.crossings(
                for: SystemPressureSample(thermal: .serious, batteryPercent: 20, onACPower: false),
                thresholds: thresholds
            ) == [.thermal, .battery])
        #expect(
            gate.crossings(
                for: SystemPressureSample(thermal: .critical, batteryPercent: 10, onACPower: false),
                thresholds: thresholds
            ).isEmpty)
        #expect(
            gate.crossings(
                for: SystemPressureSample(thermal: .fair, batteryPercent: 30, onACPower: false),
                thresholds: thresholds
            ).isEmpty)
        #expect(
            gate.crossings(
                for: SystemPressureSample(thermal: .serious, batteryPercent: 20, onACPower: false),
                thresholds: thresholds
            ) == [.thermal, .battery])
    }
}
