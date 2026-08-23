import Foundation
import Testing

@testable import CleanroomCore

@Suite("Device-specific calibration")
struct DeviceCalibrationTests {
    @Test("calibration is bounded, keyed by hardware, and privately persisted")
    func calibrationRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-calibration-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDeviceCalibrationStore(directoryURL: directory)
        let calibration = DeviceCalibration(
            hardwareIdentifier: "hardware-a",
            pointerLinearEnabled: false,
            preferredDisplayRefreshRateHertz: 240,
            automaticRestoreDebounceSeconds: 12.5
        )

        try await store.saveCalibration(calibration)

        #expect(try await store.calibration(for: "hardware-a") == calibration)
        #expect(try await store.calibration(for: "hardware-b") == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.calibrationsURL.path)
        #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
        #expect(throws: CleanroomError.self) {
            try DeviceCalibration(
                hardwareIdentifier: "hardware-a",
                preferredDisplayRefreshRateHertz: 500
            ).validate()
        }
    }

    @Test("pointer calibration rewrites only the pointer target")
    func pointerCalibrationIsAppliedToProfile() {
        let profile = CleanroomProfile.phantomForces().applying(
            DeviceCalibration(hardwareIdentifier: "hardware-a", pointerLinearEnabled: false)
        )

        #expect(
            profile.preferences.first {
                $0.domain == "NSGlobalDomain" && $0.key == "com.apple.mouse.linear"
            }?.activeValue == "false"
        )
        #expect(
            profile.preferences.first { $0.key == "USBMouseStopsTrackpad" }?.activeValue == "true"
        )
        #expect(profile.suppressBuiltInTrackpadWhenLidOpen)
    }
}
