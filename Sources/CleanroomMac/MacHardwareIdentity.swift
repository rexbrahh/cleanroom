import CryptoKit
import Foundation
import IOKit

public enum MacHardwareIdentity {
    public static var current: String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return "unknown" }
        defer { IOObjectRelease(service) }
        guard
            let value = IORegistryEntryCreateCFProperty(
                service,
                "IOPlatformUUID" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String
        else { return "unknown" }
        return SHA256.hash(data: Data(value.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
