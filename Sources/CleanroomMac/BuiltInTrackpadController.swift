import CleanroomCore
import Foundation
import IOKit
import IOKit.hid

public struct BuiltInTrackpadObservation: Sendable, Equatable {
    public let lid: LidState
    public let externalPointer: DevicePresence
    public let builtInTrackpadPresent: Bool
    public let currentlySuppressed: Bool
    public let listenEventAccessGranted: Bool

    public init(
        lid: LidState,
        externalPointer: DevicePresence,
        builtInTrackpadPresent: Bool,
        currentlySuppressed: Bool,
        listenEventAccessGranted: Bool
    ) {
        self.lid = lid
        self.externalPointer = externalPointer
        self.builtInTrackpadPresent = builtInTrackpadPresent
        self.currentlySuppressed = currentlySuppressed
        self.listenEventAccessGranted = listenEventAccessGranted
    }
}

public protocol BuiltInTrackpadControlling: Sendable {
    func observe() async -> BuiltInTrackpadObservation
    func suppress() async -> ActionResult
    func restore() async -> ActionResult
}

public enum ListenEventAccess {
    public static func isGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    public static func request() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

/// Deterministic controller used by tests and as the MacSystemController default
/// so unit tests never seize the host trackpad.
public actor NullBuiltInTrackpadController: BuiltInTrackpadControlling {
    public init() {}

    public func observe() -> BuiltInTrackpadObservation {
        BuiltInTrackpadObservation(
            lid: .unknown,
            externalPointer: .unknown,
            builtInTrackpadPresent: false,
            currentlySuppressed: false,
            listenEventAccessGranted: false
        )
    }

    public func suppress() -> ActionResult {
        ActionResult(
            action: "suppress built-in trackpad",
            target: "built-in-trackpad",
            outcome: .warning,
            detail: "Trackpad suppression is unavailable in this controller."
        )
    }

    public func restore() -> ActionResult {
        ActionResult(
            action: "restore built-in trackpad",
            target: "built-in-trackpad",
            outcome: .skipped,
            detail: "No built-in trackpad seize was held."
        )
    }
}

private let discardHIDInput: IOHIDValueCallback = { _, _, _, _ in }

public actor IOHIDBuiltInTrackpadController: BuiltInTrackpadControlling {
    private var seizedDevices: [IOHIDDevice] = []

    public init() {}

    public func observe() -> BuiltInTrackpadObservation {
        let inventory = HIDDeviceInventory.current()
        return BuiltInTrackpadObservation(
            lid: LidProbe.state(),
            externalPointer: inventory.externalPointer,
            builtInTrackpadPresent: !inventory.builtInTrackpads.isEmpty,
            currentlySuppressed: !seizedDevices.isEmpty,
            listenEventAccessGranted: ListenEventAccess.isGranted()
        )
    }

    public func suppress() -> ActionResult {
        restoreHeldDevices()
        let inventory = HIDDeviceInventory.current()
        guard !inventory.builtInTrackpads.isEmpty else {
            return ActionResult(
                action: "suppress built-in trackpad",
                target: "built-in-trackpad",
                outcome: .warning,
                detail: "No built-in trackpad was found."
            )
        }
        guard ListenEventAccess.isGranted() else {
            return ActionResult(
                action: "suppress built-in trackpad",
                target: "built-in-trackpad",
                outcome: .warning,
                detail: "Input Monitoring is not granted."
            )
        }

        var opened: [IOHIDDevice] = []
        var failures: [String] = []
        for device in inventory.builtInTrackpads {
            IOHIDDeviceRegisterInputValueCallback(device, discardHIDInput, nil)
            if let runLoop = CFRunLoopGetMain() {
                IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            }
            let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if status == kIOReturnSuccess {
                opened.append(device)
            } else {
                failures.append(String(format: "IOReturn 0x%08x", status))
            }
        }
        seizedDevices = opened
        guard !opened.isEmpty else {
            return ActionResult(
                action: "suppress built-in trackpad",
                target: "built-in-trackpad",
                outcome: .warning,
                detail: "Could not seize the built-in trackpad: \(failures.joined(separator: "; "))."
            )
        }
        return ActionResult(
            action: "suppress built-in trackpad",
            target: "built-in-trackpad",
            outcome: .succeeded,
            detail: "Seized \(opened.count) built-in trackpad device(s)."
        )
    }

    public func restore() -> ActionResult {
        guard !seizedDevices.isEmpty else {
            return ActionResult(
                action: "restore built-in trackpad",
                target: "built-in-trackpad",
                outcome: .skipped,
                detail: "No built-in trackpad seize was held."
            )
        }
        restoreHeldDevices()
        return ActionResult(
            action: "restore built-in trackpad",
            target: "built-in-trackpad",
            outcome: .succeeded,
            detail: "Released the built-in trackpad."
        )
    }

    private func restoreHeldDevices() {
        for device in seizedDevices {
            if let runLoop = CFRunLoopGetMain() {
                IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            }
            IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        seizedDevices.removeAll()
    }
}

enum LidProbe {
    static func state() -> LidState {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return .unknown }
        defer { IOObjectRelease(service) }
        guard
            let value = IORegistryEntryCreateCFProperty(
                service,
                "AppleClamshellState" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        else { return .unknown }
        if let closed = value as? Bool {
            return closed ? .closed : .open
        }
        if let number = value as? NSNumber {
            return number.boolValue ? .closed : .open
        }
        return .unknown
    }
}

private struct HIDDeviceInventory {
    let builtInTrackpads: [IOHIDDevice]
    let externalPointer: DevicePresence

    static func current() -> Self {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard opened == kIOReturnSuccess else {
            return HIDDeviceInventory(builtInTrackpads: [], externalPointer: .unknown)
        }
        guard let copied = IOHIDManagerCopyDevices(manager) else {
            return HIDDeviceInventory(builtInTrackpads: [], externalPointer: .absent)
        }
        let devices = hidDevices(from: copied)
        let builtIn = devices.filter(isBuiltInTrackpad)
        let hasExternalPointer = devices.contains(where: isExternalPointer)
        return HIDDeviceInventory(
            builtInTrackpads: Array(builtIn),
            externalPointer: hasExternalPointer ? .present : .absent
        )
    }
}

private func hidDevices(from set: CFSet) -> [IOHIDDevice] {
    (set as NSSet).allObjects.compactMap { value -> IOHIDDevice? in
        let object = value as AnyObject
        guard CFGetTypeID(object) == IOHIDDeviceGetTypeID() else { return nil }
        return (object as! IOHIDDevice)
    }
}

private func hidString(_ device: IOHIDDevice, _ key: String) -> String {
    (IOHIDDeviceGetProperty(device, key as CFString) as? String ?? "").lowercased()
}

private func hidNumber(_ device: IOHIDDevice, _ key: String) -> Int? {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
}

private func hidBool(_ device: IOHIDDevice, _ key: String) -> Bool {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.boolValue ?? false
}

private func isBuiltInTrackpad(_ device: IOHIDDevice) -> Bool {
    let transport = hidString(device, kIOHIDTransportKey)
    let product = hidString(device, kIOHIDProductKey)
    let usagePage = hidNumber(device, kIOHIDPrimaryUsagePageKey) ?? 0
    let usage = hidNumber(device, kIOHIDPrimaryUsageKey) ?? 0
    let looksLikeTrackpad =
        product.contains("trackpad")
        || (usagePage == Int(kHIDPage_Digitizer) && usage == Int(kHIDUsage_Dig_TouchPad))
    guard looksLikeTrackpad else { return false }
    if transport.contains("usb") || transport.contains("bluetooth") {
        return false
    }
    return hidBool(device, "Built-In")
        || transport.contains("spi")
        || transport.contains("i2c")
        || transport.contains("built")
        || hidNumber(device, kIOHIDVendorIDKey) == 0x05AC
}

private func isExternalPointer(_ device: IOHIDDevice) -> Bool {
    if isBuiltInTrackpad(device) { return false }
    let product = hidString(device, kIOHIDProductKey)
    if product.contains("mouse") || product.contains("razer") {
        return true
    }
    let usagePage = hidNumber(device, kIOHIDPrimaryUsagePageKey) ?? 0
    let usage = hidNumber(device, kIOHIDPrimaryUsageKey) ?? 0
    return usagePage == Int(kHIDPage_GenericDesktop)
        && (usage == Int(kHIDUsage_GD_Mouse) || usage == Int(kHIDUsage_GD_Pointer))
}
