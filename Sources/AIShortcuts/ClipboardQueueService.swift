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
    private var copyPressTracker = ClipboardQueueCopyPressTracker()
    private var captureGeneration = 0
    private var pasteAdvanceGeneration = 0
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalEventMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var pasteSession: ClipboardQueuePasteSession<ClipboardPayload>?
    private var lastCopyTimestamp: TimeInterval = 0
    private var lastPasteTimestamp: TimeInterval = 0

    init(eventHandler: @escaping @Sendable (ClipboardQueueEvent) -> Void) {
        self.eventHandler = eventHandler
    }

    var mode: ClipboardQueueMode {
        stateLock.withLock { activeMode }
    }

    var count: Int {
        stateLock.withLock {
            switch activeMode {
            case .inactive:
                return 0
            case .collecting:
                return queue.count
            case .pasting:
                return pasteSession?.count ?? 0
            }
        }
    }

    func startCollecting() -> Bool {
        deactivate(notify: false)

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        let source = tap.flatMap { CFMachPortCreateRunLoopSource(kCFAllocatorDefault, $0, 0) }

        stateLock.withLock {
            activeMode = .collecting
            queue.reset()
            queuedBytes = 0
            copyBaselineChangeCount = nil
            copyPressTracker.reset()
            captureGeneration += 1
            pasteAdvanceGeneration += 1
            pasteSession = nil
            lastCopyTimestamp = 0
            lastPasteTimestamp = 0
            eventTap = tap
            runLoopSource = source
        }

        if let tap, let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.mode == .collecting else { return }
            self.installGlobalMonitorIfNeeded()
            self.installWorkspaceObserverIfNeeded()
        }

        eventHandler(.changed(mode: .collecting, count: 0))
        return true
    }

    func beginPasting() {
        let (firstPayload, totalCount) = stateLock.withLock { () -> (ClipboardPayload?, Int) in
            guard activeMode == .collecting, !queue.isEmpty else {
                return (nil, 0)
            }
            activeMode = .pasting
            let session = ClipboardQueuePasteSession(queue: &queue)
            let first = session.current
            pasteSession = session
            lastPasteTimestamp = ProcessInfo.processInfo.systemUptime
            pasteAdvanceGeneration += 1
            return (first, session.count)
        }
        if let firstPayload {
            firstPayload.write(to: .general)
            eventHandler(.changed(mode: .pasting, count: totalCount))
        } else {
            deactivate(notify: true)
        }
    }

    func deactivate(notify: Bool = true) {
        let (resources, monitor, observer) = stateLock.withLock { () -> ((CFMachPort?, CFRunLoopSource?), Any?, NSObjectProtocol?) in
            activeMode = .inactive
            queue.reset()
            queuedBytes = 0
            copyBaselineChangeCount = nil
            copyPressTracker.reset()
            captureGeneration += 1
            pasteAdvanceGeneration += 1
            pasteSession = nil
            lastCopyTimestamp = 0
            lastPasteTimestamp = 0
            let res = (eventTap, runLoopSource)
            let mon = globalEventMonitor
            let obs = workspaceObserver
            eventTap = nil
            runLoopSource = nil
            globalEventMonitor = nil
            workspaceObserver = nil
            return (res, mon, obs)
        }

        if let source = resources.1 {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = resources.0 {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let monitor {
            if Thread.isMainThread {
                NSEvent.removeMonitor(monitor)
            } else {
                let box = UncheckedSendableBox(monitor)
                DispatchQueue.main.async {
                    NSEvent.removeMonitor(box.value)
                }
            }
        }
        if let observer {
            if Thread.isMainThread {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            } else {
                let box = UncheckedSendableBox(observer)
                DispatchQueue.main.async {
                    NSWorkspace.shared.notificationCenter.removeObserver(box.value)
                }
            }
        }
        if notify {
            eventHandler(.changed(mode: .inactive, count: 0))
        }
    }

    deinit {
        deactivate(notify: false)
    }

    private func installGlobalMonitorIfNeeded() {
        guard globalEventMonitor == nil else { return }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleGlobalNSEvent(event)
        }
    }

    private func installWorkspaceObserverIfNeeded() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleApplicationSwitch()
        }
    }

    private func handleApplicationSwitch() {
        let (currentMode, tap, payload) = stateLock.withLock { () -> (ClipboardQueueMode, CFMachPort?, ClipboardPayload?) in
            copyPressTracker.reset()
            return (activeMode, eventTap, pasteSession?.current)
        }
        guard currentMode != .inactive else { return }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        if currentMode == .pasting, let payload {
            payload.write(to: .general)
        }
    }

    private func handleGlobalNSEvent(_ event: NSEvent) {
        let currentMode = mode
        guard currentMode != .inactive else { return }

        let flags = event.modifierFlags.intersection([.command, .option, .control])
        let isCmdOnly = flags == .command
        let isC = event.keyCode == 8 || event.charactersIgnoringModifiers?.lowercased() == "c"
        let isV = event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v"

        if event.type == .keyDown {
            if currentMode == .collecting && isCmdOnly && isC {
                handleCopyKeyDown()
            } else if currentMode == .pasting && isCmdOnly && isV {
                handlePasteKeyDown()
            } else if currentMode == .collecting && isCmdOnly && isV {
                handlePasteKeyDownWhileCollecting()
            }
        } else if event.type == .keyUp {
            if isC {
                handleCopyKeyUp()
            } else if isV {
                handlePasteKeyUp()
            }
        }
    }

    private func process(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = stateLock.withLock({ eventTap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            stateLock.withLock {
                copyPressTracker.reset()
                copyBaselineChangeCount = nil
            }
            return
        }
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else {
            return
        }

        let flagsOfInterest: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        let flags = event.flags.intersection(flagsOfInterest)
        let isCmdOnly = flags == .maskCommand
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isC = keyCode == 8
        let isV = keyCode == 9
        let currentMode = stateLock.withLock { activeMode }

        if type == .keyDown {
            if currentMode == .collecting && isCmdOnly && isC {
                handleCopyKeyDown()
            } else if currentMode == .pasting && isCmdOnly && isV {
                handlePasteKeyDown()
            } else if currentMode == .collecting && isCmdOnly && isV {
                handlePasteKeyDownWhileCollecting()
            }
        } else if type == .keyUp {
            if isC {
                handleCopyKeyUp()
            } else if isV {
                handlePasteKeyUp()
            }
        }
    }

    private func handleCopyKeyDown() {
        let (shouldCapture, baseline, generation) = stateLock.withLock { () -> (Bool, Int, Int) in
            guard activeMode == .collecting else {
                return (false, 0, 0)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCopyTimestamp < 0.12 {
                return (false, 0, 0)
            }
            guard copyPressTracker.beginKeyDown() || (now - lastCopyTimestamp > 0.8) else {
                return (false, 0, 0)
            }
            lastCopyTimestamp = now
            let baseline = NSPasteboard.general.changeCount
            copyBaselineChangeCount = baseline
            return (true, baseline, captureGeneration)
        }
        if shouldCapture {
            captureWhenChanged(from: baseline, attempt: 0, generation: generation)
        }
    }

    private func handleCopyKeyUp() {
        stateLock.withLock {
            _ = copyPressTracker.endKeyUp()
            copyBaselineChangeCount = nil
        }
    }

    private func handlePasteKeyDown() {
        let (shouldProceed, generation) = stateLock.withLock { () -> (Bool, Int) in
            guard activeMode == .pasting, let session = pasteSession, !session.isComplete else {
                return (false, 0)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPasteTimestamp < 0.10 {
                return (false, 0)
            }
            lastPasteTimestamp = now
            pasteAdvanceGeneration += 1
            return (true, pasteAdvanceGeneration)
        }
        guard shouldProceed else { return }

        // The target application receives ⌘V and pastes the current payload from NSPasteboard.general.
        // We schedule the queue advancement after a 40ms window to give the destination
        // application time to synchronously read the pasteboard without interruption.
        scheduleAdvanceAfterPaste(generation: generation)
    }

    private func handlePasteKeyUp() {
        let generation = stateLock.withLock { activeMode == .pasting ? pasteAdvanceGeneration : 0 }
        if generation > 0 {
            advancePasteQueue(generation: generation)
        }
    }

    private func handlePasteKeyDownWhileCollecting() {
        let (firstPayload, totalCount, generation) = stateLock.withLock { () -> (ClipboardPayload?, Int, Int) in
            guard activeMode == .collecting, !queue.isEmpty else { return (nil, 0, 0) }
            activeMode = .pasting
            let session = ClipboardQueuePasteSession(queue: &queue)
            let first = session.current
            pasteSession = session
            let now = ProcessInfo.processInfo.systemUptime
            lastPasteTimestamp = now
            pasteAdvanceGeneration += 1
            return (first, session.count, pasteAdvanceGeneration)
        }
        guard let firstPayload else { return }
        firstPayload.write(to: .general)
        eventHandler(.changed(mode: .pasting, count: totalCount))
        scheduleAdvanceAfterPaste(generation: generation)
    }

    private func scheduleAdvanceAfterPaste(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.040) { [weak self] in
            self?.advancePasteQueue(generation: generation)
        }
    }

    private func advancePasteQueue(generation: Int) {
        let action = stateLock.withLock { () -> (nextPayload: ClipboardPayload?, remaining: Int, shouldDeactivate: Bool)? in
            guard activeMode == .pasting,
                  pasteAdvanceGeneration == generation,
                  var session = pasteSession
            else {
                return nil
            }
            pasteAdvanceGeneration += 1

            if let next = session.advance() {
                pasteSession = session
                return (next, session.count, false)
            } else {
                pasteSession = nil
                return (nil, 0, true)
            }
        }
        guard let action else { return }

        if let nextPayload = action.nextPayload {
            nextPayload.write(to: .general)
            eventHandler(.changed(mode: .pasting, count: action.remaining))
        } else if action.shouldDeactivate {
            DispatchQueue.main.async { [weak self] in
                self?.deactivate(notify: true)
            }
        }
    }

    private func captureWhenChanged(from baseline: Int, attempt: Int, generation: Int) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ClipboardQueueCapturePolicy.retryInterval
        ) { [weak self] in
            guard let self,
                  self.mode == .collecting,
                  self.stateLock.withLock({ self.captureGeneration == generation })
            else {
                return
            }
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != baseline else {
                if attempt + 1 < ClipboardQueueCapturePolicy.maximumCaptureAttempts {
                    self.captureWhenChanged(
                        from: baseline,
                        attempt: attempt + 1,
                        generation: generation
                    )
                }
                return
            }
            guard let payload = ClipboardPayload(pasteboard: pasteboard) else {
                return
            }

            let accepted = self.stateLock.withLock { () -> Bool in
                guard self.activeMode == .collecting,
                      self.queue.count < Self.maximumItems,
                      self.queuedBytes + payload.byteCount <= Self.maximumBytes
                else {
                    return false
                }
                self.queue.enqueue(payload)
                self.queuedBytes += payload.byteCount
                return true
            }
            if accepted {
                self.eventHandler(.changed(mode: .collecting, count: self.count))
            } else {
                self.eventHandler(.captureRejected)
            }
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
        var captured = (pasteboard.pasteboardItems ?? []).compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            let values = item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) {
                result, type in
                if let data = item.data(forType: type) {
                    result[type] = data
                }
            }
            return values.isEmpty ? nil : values
        }
        if captured.isEmpty {
            if let string = pasteboard.string(forType: .string),
               let data = string.data(using: .utf8) {
                captured = [[.string: data]]
            }
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
        if !pasteboardItems.isEmpty {
            pasteboard.writeObjects(pasteboardItems)
        } else if let first = items.first, let strData = first[.string], let str = String(data: strData, encoding: .utf8) {
            pasteboard.setString(str, forType: .string)
        }
    }
}

private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}
