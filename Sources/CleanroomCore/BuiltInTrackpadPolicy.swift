import Foundation

public enum LidState: String, Sendable, Equatable {
    case open
    case closed
    case unknown
}

public enum DevicePresence: String, Sendable, Equatable {
    case present
    case absent
    case unknown
}

public enum BuiltInTrackpadPolicy {
    public static func desiredSuppressed(
        enabledInProfile: Bool,
        lid: LidState,
        externalPointer: DevicePresence,
        builtInTrackpadPresent: Bool,
        currentlySuppressed: Bool
    ) -> Bool {
        guard enabledInProfile, builtInTrackpadPresent else { return false }
        guard externalPointer == .present else { return false }
        switch lid {
        case .open:
            return true
        case .closed:
            return false
        case .unknown:
            return currentlySuppressed
        }
    }

    public static func verifyOutcome(
        desired: Bool,
        currentlySuppressed: Bool,
        listenEventAccessGranted: Bool
    ) -> ActionOutcome {
        if desired == currentlySuppressed {
            return desired ? .succeeded : .skipped
        }
        if desired, !listenEventAccessGranted {
            return .warning
        }
        return .failed
    }
}
