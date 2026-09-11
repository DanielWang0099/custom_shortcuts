import AppKit
import CoreGraphics
import Foundation

enum InputLockMode: String, Sendable {
    case keyboard
    case shortcuts

    var title: String {
        switch self {
        case .keyboard: "Keyboard locked"
        case .shortcuts: "Shortcuts locked"
        }
    }
}

final class InputLockService: @unchecked Sendable {
    private static let systemDefinedRawValue: UInt32 = 14
    private static let auxMouseButtonSubtype: Int16 = 7

    private let stateLock = NSLock()
    private let unlockHandler: @Sendable () -> Void
    private var activeMode: InputLockMode?
    private var unlockRequested = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(unlockHandler: @escaping @Sendable () -> Void) {
        self.unlockHandler = unlockHandler
    }

    var mode: InputLockMode? {
        stateLock.withLock { activeMode }
    }

    func activate(_ mode: InputLockMode) -> Bool {
        deactivate()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << Self.systemDefinedRawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }

        stateLock.withLock {
            activeMode = mode
            unlockRequested = false
            eventTap = tap
            runLoopSource = source
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func deactivate() {
        let resources = stateLock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
            activeMode = nil
            unlockRequested = false
            let resources = (eventTap, runLoopSource)
            eventTap = nil
            runLoopSource = nil
            return resources
        }
        if let source = resources.1 {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = resources.0 {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    deinit {
        deactivate()
    }

    private func process(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type.rawValue == 0xFFFFFFFF {
            if let tap = stateLock.withLock({ eventTap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        let snapshot = stateLock.withLock { (activeMode, unlockRequested) }
        guard let mode = snapshot.0 else {
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let shortcutFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        let activeShortcutFlags = event.flags.intersection(shortcutFlags)
        let isUnlockChord = keyCode == 37 && activeShortcutFlags == shortcutFlags
        if isUnlockChord {
            if type == .keyDown, !snapshot.1 {
                stateLock.withLock { unlockRequested = true }
                unlockHandler()
            }
            return true
        }

        switch mode {
        case .keyboard:
            if type == .keyDown || type == .keyUp || type == .flagsChanged {
                return true
            }
            if type.rawValue == Self.systemDefinedRawValue {
                // Filter out mouse auxiliary buttons if delivered as system-defined
                if let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == Self.auxMouseButtonSubtype {
                    return false
                }
                // Suppress upper keyboard row F1-F12 media, brightness, volume, and control keys
                return true
            }
            return false
        case .shortcuts:
            let isKeyOrSystem = type == .keyDown || type == .keyUp || type.rawValue == Self.systemDefinedRawValue
            return isKeyOrSystem && !activeShortcutFlags.isEmpty
        }
    }

    private static let eventCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let service = Unmanaged<InputLockService>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return service.process(type: type, event: event)
            ? nil
            : Unmanaged.passUnretained(event)
    }
}
