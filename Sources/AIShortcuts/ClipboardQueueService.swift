import AppKit
import AIShortcutsCore
import CoreGraphics
import Darwin
import Foundation

enum ClipboardQueueMode: Sendable {
    case inactive
    case collecting
    case pasting
}

enum ClipboardQueueEvent: Sendable {
    case changed(mode: ClipboardQueueMode, count: Int)
    case captureRejected
}

final class ClipboardQueueService: @unchecked Sendable {
    private static let maximumItems = 50
    private static let maximumBytes = 100 * 1_024 * 1_024

    private let stateLock = NSLock()
    private let eventHandler: @Sendable (ClipboardQueueEvent) -> Void
    private var activeMode: ClipboardQueueMode = .inactive
    private var queue = FIFOQueue<ClipboardPayload>()
    private var queuedBytes = 0
    private var copyBaselineChangeCount: Int?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(eventHandler: @escaping @Sendable (ClipboardQueueEvent) -> Void) {
        self.eventHandler = eventHandler
    }

    var mode: ClipboardQueueMode {
        stateLock.withLock { activeMode }
    }

    var count: Int {
        stateLock.withLock { queue.count }
    }

    func startCollecting() -> Bool {
        deactivate(notify: false)

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
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
            activeMode = .collecting
            queue.reset()
            queuedBytes = 0
            copyBaselineChangeCount = nil
            eventTap = tap
            runLoopSource = source
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventHandler(.changed(mode: .collecting, count: 0))
        return true
    }

    func beginPasting() {
        let itemCount = stateLock.withLock { () -> Int in
            guard activeMode == .collecting else {
                return queue.count
            }
            activeMode = queue.isEmpty ? .inactive : .pasting
            return queue.count
        }
        if itemCount == 0 {
            deactivate(notify: true)
        } else {
            eventHandler(.changed(mode: .pasting, count: itemCount))
        }
    }

    func deactivate(notify: Bool = true) {
        let resources = stateLock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
            activeMode = .inactive
            queue.reset()
            queuedBytes = 0
            copyBaselineChangeCount = nil
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
        if notify {
            eventHandler(.changed(mode: .inactive, count: 0))
        }
    }

    deinit {
        deactivate(notify: false)
    }

    private func process(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout {
            if let tap = stateLock.withLock({ eventTap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else {
            return
        }

        let flagsOfInterest: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        let flags = event.flags.intersection(flagsOfInterest)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let currentMode = stateLock.withLock { activeMode }

        if currentMode == .collecting, keyCode == 8, flags == .maskCommand {
            if type == .keyDown {
                stateLock.withLock {
                    copyBaselineChangeCount = NSPasteboard.general.changeCount
                }
            } else if type == .keyUp {
                let baseline = stateLock.withLock { () -> Int in
                    defer { copyBaselineChangeCount = nil }
                    return copyBaselineChangeCount ?? NSPasteboard.general.changeCount
                }
                captureWhenChanged(from: baseline, attempt: 0)
            }
            return
        }

        if currentMode == .pasting,
           type == .keyDown,
           keyCode == 9,
           flags == .maskCommand
        {
            prepareNextPaste()
        }
    }

    private func captureWhenChanged(from baseline: Int, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.018) { [weak self] in
            guard let self, mode == .collecting else {
                return
            }
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != baseline else {
                if attempt < 24 {
                    captureWhenChanged(from: baseline, attempt: attempt + 1)
                }
                return
            }
            guard let payload = ClipboardPayload(pasteboard: pasteboard) else {
                return
            }

            let accepted = stateLock.withLock { () -> Bool in
                guard activeMode == .collecting,
                      queue.count < Self.maximumItems,
                      queuedBytes + payload.byteCount <= Self.maximumBytes
                else {
                    return false
                }
                queue.enqueue(payload)
                queuedBytes += payload.byteCount
                return true
            }
            if accepted {
                eventHandler(.changed(mode: .collecting, count: count))
            } else {
                eventHandler(.captureRejected)
            }
        }
    }

    private func prepareNextPaste() {
        let result = stateLock.withLock { () -> (ClipboardPayload?, Int) in
            guard activeMode == .pasting, !queue.isEmpty else {
                return (nil, queue.count)
            }
            guard let payload = queue.dequeue() else {
                return (nil, 0)
            }
            queuedBytes = max(0, queuedBytes - payload.byteCount)
            return (payload, queue.count)
        }
        guard let payload = result.0 else {
            return
        }
        payload.write(to: .general)

        if result.1 == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.deactivate(notify: true)
            }
        } else {
            eventHandler(.changed(mode: .pasting, count: result.1))
        }
    }

    private static let eventCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let service = Unmanaged<ClipboardQueueService>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        service.process(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }
}

private struct ClipboardPayload: @unchecked Sendable {
    let items: [[NSPasteboard.PasteboardType: Data]]
    let byteCount: Int

    init?(pasteboard: NSPasteboard) {
        let captured = (pasteboard.pasteboardItems ?? []).compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            let values = item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) {
                result, type in
                if let data = item.data(forType: type) {
                    result[type] = data
                }
            }
            return values.isEmpty ? nil : values
        }
        guard !captured.isEmpty else {
            return nil
        }
        items = captured
        byteCount = captured.reduce(0) { total, item in
            total + item.values.reduce(0) { $0 + $1.count }
        }
    }

    func write(to pasteboard: NSPasteboard) {
        let pasteboardItems = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(pasteboardItems)
    }
}
