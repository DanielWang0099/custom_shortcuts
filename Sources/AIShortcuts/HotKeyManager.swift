import AIShortcutsCore
import Carbon
import Foundation

@MainActor
final class HotKeyManager {
    private static let signature: OSType = 0x4149_5348 // "AISH"

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [AIShortcutAction: EventHotKeyRef] = [:]
    private let handler: @MainActor (AIShortcutAction) -> Void

    init(
        enabledActions: Set<AIShortcutAction>,
        handler: @escaping @MainActor (AIShortcutAction) -> Void
    ) throws {
        self.handler = handler

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.carbonHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            throw HotKeyError.registrationFailed(installStatus)
        }

        for definition in HotKeyDefinition.defaults where enabledActions.contains(definition.action) {
            try register(definition)
        }
    }

    func setEnabled(_ enabled: Bool, for action: AIShortcutAction) throws {
        if enabled {
            guard hotKeyRefs[action] == nil,
                  let definition = HotKeyDefinition.defaults.first(where: { $0.action == action })
            else {
                return
            }
            try register(definition)
        } else if let reference = hotKeyRefs.removeValue(forKey: action) {
            let status = UnregisterEventHotKey(reference)
            guard status == noErr else {
                hotKeyRefs[action] = reference
                throw HotKeyError.registrationFailed(status)
            }
        }
    }

    private func register(_ definition: HotKeyDefinition) throws {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(
            signature: Self.signature,
            id: definition.action.rawValue
        )
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        let status = RegisterEventHotKey(
            definition.virtualKeyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw HotKeyError.registrationFailed(status)
        }
        hotKeyRefs[definition.action] = reference
    }

    private func dispatch(_ action: AIShortcutAction) {
        handler(action)
    }

    private static let carbonHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else {
            return OSStatus(eventNotHandledErr)
        }
        // Dispatch on release so synthesized Command-C is never combined with
        // the user's still-held Control/Option/Command chord.
        guard GetEventKind(event) == UInt32(kEventHotKeyReleased) else {
            return noErr
        }
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
              identifier.signature == HotKeyManager.signature,
              let action = AIShortcutAction(rawValue: identifier.id)
        else {
            return OSStatus(eventNotHandledErr)
        }

        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
            manager.dispatch(action)
        }
        return noErr
    }
}

enum HotKeyError: LocalizedError {
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .registrationFailed(status):
            "The global shortcuts could not be registered (Carbon error \(status))."
        }
    }
}
