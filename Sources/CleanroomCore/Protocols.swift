import Foundation

public protocol RecoveryJournalPersisting: Sendable {
    func journalExists() async -> Bool
    func loadJournal() async throws -> RecoveryJournal?
    func saveJournal(_ journal: RecoveryJournal) async throws
    func clearJournal() async throws
}

public protocol RuntimePreferencesPersisting: Sendable {
    func loadPreferences() async throws -> RuntimePreferences
    func savePreferences(_ preferences: RuntimePreferences) async throws
}

public protocol RecoveryReceiptPersisting: Sendable {
    func saveReceipt(_ receipt: RecoveryReceipt) async throws
    func recentReceipts(limit: Int) async throws -> [RecoveryReceipt]
}

public protocol ProfilePersisting: Sendable {
    func loadProfiles() async throws -> [CleanroomProfile]
    func saveProfiles(_ profiles: [CleanroomProfile]) async throws
}

public protocol DeviceCalibrationPersisting: Sendable {
    func calibration(for hardwareIdentifier: String) async throws -> DeviceCalibration?
    func saveCalibration(_ calibration: DeviceCalibration) async throws
}

public protocol CleanroomSystemControlling: Sendable {
    func probeTrigger() async -> TriggerProbe
    func probeTrigger(bundleIdentifier: String) async -> TriggerProbe
    func captureSnapshot(for profile: CleanroomProfile) async throws -> SystemSnapshot
    func apply(profile: CleanroomProfile) async -> [ActionResult]
    func verifyApplied(profile: CleanroomProfile) async -> [ActionResult]
    func restore(snapshot: SystemSnapshot, profile: CleanroomProfile) async -> [ActionResult]
    func preflight(profile: CleanroomProfile) async -> PreflightReport
    func launchTrigger(bundleIdentifier: String) async -> ActionResult
}

extension CleanroomSystemControlling {
    public func probeTrigger(bundleIdentifier: String) async -> TriggerProbe {
        await probeTrigger()
    }

    public func launchTrigger(bundleIdentifier: String) async -> ActionResult {
        ActionResult(
            action: "launch trigger",
            target: bundleIdentifier,
            outcome: .failed,
            detail: "This system controller does not support launching the trigger application."
        )
    }
}
