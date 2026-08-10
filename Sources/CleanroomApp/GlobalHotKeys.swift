import Carbon
import CleanroomProtocol
import Foundation

enum GlobalHotKeyAction: UInt32, CaseIterable, Sendable {
    case status = 1
    case preflight
    case safeLaunch
    case togglePause
    case restore

    var keyCode: UInt32 {
        switch self {
        case .status: UInt32(kVK_ANSI_S)
        case .preflight: UInt32(kVK_ANSI_P)
        case .safeLaunch: UInt32(kVK_ANSI_L)
        case .togglePause: UInt32(kVK_ANSI_C)
        case .restore: UInt32(kVK_ANSI_R)
        }
    }

    var agentCommand: AgentCommand? {
        switch self {
        case .status: .status
        case .preflight: .preflight
        case .safeLaunch: .safeLaunch
        case .togglePause: nil
        case .restore: .restore
        }
    }
}

@MainActor
final class GlobalHotKeyController {
    private static let signature: OSType = 0x434C_524D  // CLRM
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var hotKeys: [EventHotKeyRef] = []
    private let action: @MainActor (GlobalHotKeyAction) -> Void

    init(action: @escaping @MainActor (GlobalHotKeyAction) -> Void) {
        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return noErr }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr,
                    identifier.signature == GlobalHotKeyController.signature,
                    let action = GlobalHotKeyAction(rawValue: identifier.id)
                else { return status }
                let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(context)
                    .takeUnretainedValue()
                Task { @MainActor in controller.action(action) }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        for action in GlobalHotKeyAction.allCases {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            if RegisterEventHotKey(
                action.keyCode,
                modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            ) == noErr, let reference {
                hotKeys.append(reference)
            }
        }
    }

    deinit {
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
