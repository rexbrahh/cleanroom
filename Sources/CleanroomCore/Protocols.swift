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

public protocol CleanroomSystemControlling: Sendable {
    func probeTrigger() async -> TriggerProbe
    func captureSnapshot(for profile: CleanroomProfile) async throws -> SystemSnapshot
    func apply(profile: CleanroomProfile) async -> [ActionResult]
    func verifyApplied(profile: CleanroomProfile) async -> [ActionResult]
    func restore(snapshot: SystemSnapshot, profile: CleanroomProfile) async -> [ActionResult]
    func preflight(profile: CleanroomProfile) async -> PreflightReport
}
