import CleanroomCore
import CoreFoundation
import Foundation

/// Reads preference values in-process through CFPreferences instead of
/// spawning a `defaults` subprocess per key. Drift verification runs every
/// fifteen seconds during gameplay, so steady-state inspection must not
/// launch shell probes. Writes still go through the `defaults` binary; the
/// read search list (current user, any host) matches what `defaults read`
/// uses, so values round-trip consistently.
public protocol PreferenceReading: Sendable {
    func readStored(_ preference: PreferenceAction) async throws -> StoredPreference
}

public struct CFPreferenceReader: PreferenceReading {
    public init() {}

    public func readStored(_ preference: PreferenceAction) throws -> StoredPreference {
        let application: CFString =
            preference.domain == "NSGlobalDomain"
            ? kCFPreferencesAnyApplication
            : preference.domain as CFString

        guard
            let value = CFPreferencesCopyAppValue(
                preference.key as CFString,
                application
            )
        else {
            return StoredPreference(
                domain: preference.domain,
                key: preference.key,
                kind: preference.kind,
                wasPresent: false,
                value: nil
            )
        }

        func stored(_ string: String) -> StoredPreference {
            StoredPreference(
                domain: preference.domain,
                key: preference.key,
                kind: preference.kind,
                wasPresent: true,
                value: string
            )
        }

        switch preference.kind {
        case .boolean:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return stored(CFBooleanGetValue(value as! CFBoolean) ? "1" : "0")
            }
            if let number = value as? NSNumber {
                return stored(number.boolValue ? "1" : "0")
            }
            if let string = value as? String {
                return stored(string)
            }
        case .integer:
            if let number = value as? NSNumber, CFGetTypeID(value) == CFNumberGetTypeID() {
                return stored("\(number.intValue)")
            }
            if let string = value as? String, Int(string) != nil {
                return stored(string)
            }
        case .string:
            if let string = value as? String {
                return stored(string)
            }
        }

        throw CleanroomError.mutationFailed(
            "Preference \(preference.domain):\(preference.key) has an unsupported value type."
        )
    }
}
