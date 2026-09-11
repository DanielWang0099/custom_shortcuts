import AppKit
import AIShortcutsCore
import Carbon
import Foundation

@MainActor
final class HotKeyManager {
    private static let signature: OSType = 0x4149_5348 // "AISH"

    private var eventHandlerRef: EventHandlerRef?
    private var modifierMonitor: Any?
    private var hotKeyRefs: [AIShortcutAction: EventHotKeyRef] = [:]
    private let activationHandler: @MainActor () -> Void
    private let preparationHandler: @MainActor (AIShortcutAction) -> Void
    private let handler: @MainActor (AIShortcutAction) -> Void
    private var activationChordIsDown = false

    init(
        enabledActions: Set<AIShortcutAction>,
        onActivationChord: @escaping @MainActor () -> Void,
        onActionPressed: @escaping @MainActor (AIShortcutAction) -> Void,
        handler: @escaping @MainActor (AIShortcutAction) -> Void
    ) throws {
        activationHandler = onActivationChord
        preparationHandler = onActionPressed
        self.handler = handler

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventRawKeyModifiersChanged)
            ),
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

        do {
            for definition in HotKeyDefinition.defaults where enabledActions.contains(definition.action) {
                try register(definition)
            }
        } catch {
            tearDown()
            throw error
        }

        // Carbon remains the action dispatcher. This flags-only monitor gives
        // the shared modifier chord a documented system-wide wake signal while
        // the accessory app is in the background. The action key-down path is
        // still the fallback when Accessibility has not yet been granted.
        modifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            let required: NSEvent.ModifierFlags = [.command, .option, .control]
            let isDown = event.modifierFlags.intersection(required) == required
            Task(priority: .high) { @MainActor [weak self] in
                self?.updateActivationChord(isDown: isDown)
            }
        }
    }

    func invalidate() {
        tearDown()
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

    private func prepare(_ action: AIShortcutAction) {
        preparationHandler(action)
    }

    private func updateActivationChord(modifiers: UInt32) {
        let required = UInt32(cmdKey | optionKey | controlKey)
        updateActivationChord(isDown: (modifiers & required) == required)
    }

    private func updateActivationChord(isDown: Bool) {
        guard isDown != activationChordIsDown else {
            return
        }
        activationChordIsDown = isDown
        if isDown {
            activationHandler()
        }
    }

    private func tearDown() {
        if let modifierMonitor {
            NSEvent.removeMonitor(modifierMonitor)
            self.modifierMonitor = nil
        }
        for reference in hotKeyRefs.values {
            UnregisterEventHotKey(reference)
        }
        hotKeyRefs.removeAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private static let carbonHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else {
            return OSStatus(eventNotHandledErr)
        }
        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        let kind = GetEventKind(event)

        if kind == UInt32(kEventRawKeyModifiersChanged) {
            var modifiers: UInt32 = 0
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamKeyModifiers),
                EventParamType(typeUInt32),
                nil,
                MemoryLayout<UInt32>.size,
                nil,
                &modifiers
            )
            guard status == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            Task(priority: .high) { @MainActor in
                manager.updateActivationChord(modifiers: modifiers)
            }
            return OSStatus(eventNotHandledErr)
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

        if kind == UInt32(kEventHotKeyPressed) {
            Task(priority: .high) { @MainActor in
                manager.prepare(action)
            }
            return noErr
        }
        if kind == UInt32(kEventHotKeyReleased) {
            // Dispatch on release so synthesized Command-C is never combined
            // with the user's still-held Control/Option/Command chord.
            Task(priority: .high) { @MainActor in
                manager.dispatch(action)
            }
            return noErr
        }
        return OSStatus(eventNotHandledErr)
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
