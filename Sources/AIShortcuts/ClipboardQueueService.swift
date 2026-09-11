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
    private var copyPressTracker = ClipboardQueueCopyPressTracker()
    private var copyCaptureTracker = ClipboardQueueCaptureTracker()
    private var captureGeneration = 0
    private var capturePollScheduled = false
    private var captureDeadline: TimeInterval = 0
    private var pastePressTracker = ClipboardQueueCopyPressTracker()
    private var pasteAdvanceGeneration = 0
    private var pendingPasteAdvanceGeneration: Int?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalEventMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var pasteSession: ClipboardQueuePasteSession<ClipboardPayload>?

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
        let initialChangeCount = NSPasteboard.general.changeCount

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
        let activeTap = source == nil ? nil : tap
        let activeSource = tap == nil ? nil : source

        stateLock.withLock {
            activeMode = .collecting
            queue.reset()
            queuedBytes = 0
            copyPressTracker.reset()
            copyCaptureTracker = ClipboardQueueCaptureTracker(
                initialChangeCount: initialChangeCount
            )
            captureGeneration += 1
            capturePollScheduled = false
            captureDeadline = 0
            pastePressTracker.reset()
            pasteAdvanceGeneration += 1
            pendingPasteAdvanceGeneration = nil
            pasteSession = nil
            eventTap = activeTap
            runLoopSource = activeSource
        }

        if let activeTap, let activeSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), activeSource, .commonModes)
            CGEvent.tapEnable(tap: activeTap, enable: true)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.mode == .collecting else { return }
            if self.stateLock.withLock({ self.eventTap == nil }) {
                self.installGlobalMonitorIfNeeded()
            }
            self.installWorkspaceObserverIfNeeded()
        }

        eventHandler(.changed(mode: .collecting, count: 0))
        return true
    }

    func beginPasting() {
        let captureGeneration = stateLock.withLock { self.captureGeneration }
        captureAvailablePasteboardChange(generation: captureGeneration)
        let currentChangeCount = NSPasteboard.general.changeCount
        let (firstPayload, totalCount) = stateLock.withLock { () -> (ClipboardPayload?, Int) in
            guard activeMode == .collecting, !queue.isEmpty else {
                return (nil, 0)
            }
            activeMode = .pasting
            self.captureGeneration += 1
            capturePollScheduled = false
            captureDeadline = 0
            copyCaptureTracker.discardPendingCopies(
                observedChangeCount: currentChangeCount
            )
            copyPressTracker.reset()
            let session = ClipboardQueuePasteSession(queue: &queue)
            let first = session.current
            pasteSession = session
            pastePressTracker.reset()
            pasteAdvanceGeneration += 1
            pendingPasteAdvanceGeneration = nil
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
            copyPressTracker.reset()
            copyCaptureTracker = ClipboardQueueCaptureTracker()
            captureGeneration += 1
            capturePollScheduled = false
            captureDeadline = 0
            pastePressTracker.reset()
            pasteAdvanceGeneration += 1
            pendingPasteAdvanceGeneration = nil
            pasteSession = nil
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
        let (currentMode, tap, payload, generation) = stateLock.withLock {
            () -> (ClipboardQueueMode, CFMachPort?, ClipboardPayload?, Int) in
            copyPressTracker.reset()
            pastePressTracker.reset()
            return (activeMode, eventTap, pasteSession?.current, captureGeneration)
        }
        guard currentMode != .inactive else { return }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        if currentMode == .collecting {
            captureAvailablePasteboardChange(generation: generation)
            scheduleCapturePoll(generation: generation)
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
                handleCopyKeyDown(
                    isRepeat: event.isARepeat,
                    isBeforeTargetDelivery: false
                )
            } else if currentMode == .pasting && isCmdOnly && isV {
                handlePasteKeyDown(isRepeat: event.isARepeat)
            } else if currentMode == .collecting && isCmdOnly && isV {
                handlePasteKeyDownWhileCollecting(isRepeat: event.isARepeat)
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
                pastePressTracker.reset()
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
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let currentMode = stateLock.withLock { activeMode }

        if type == .keyDown {
            if currentMode == .collecting && isCmdOnly && isC {
                handleCopyKeyDown(
                    isRepeat: isRepeat,
                    isBeforeTargetDelivery: true
                )
            } else if currentMode == .pasting && isCmdOnly && isV {
                handlePasteKeyDown(isRepeat: isRepeat)
            } else if currentMode == .collecting && isCmdOnly && isV {
                handlePasteKeyDownWhileCollecting(isRepeat: isRepeat)
            }
        } else if type == .keyUp {
            if isC {
                handleCopyKeyUp()
            } else if isV {
                handlePasteKeyUp()
            }
        }
    }

    private func handleCopyKeyDown(
        isRepeat: Bool,
        isBeforeTargetDelivery: Bool
    ) {
        guard !isRepeat else {
            return
        }
        let generation = stateLock.withLock { () -> Int? in
            guard activeMode == .collecting else {
                return nil
            }
            if !copyPressTracker.beginKeyDown() {
                // A non-repeat key-down means this is a new physical press even
                // if a prior key-up was lost during an application switch.
                copyPressTracker.reset()
                guard copyPressTracker.beginKeyDown() else {
                    return nil
                }
            }
            return captureGeneration
        }
        guard let generation else {
            return
        }

        if isBeforeTargetDelivery {
            // The event tap runs before the source app handles the new Copy.
            // Capture any prior delayed result now, while it is still present.
            captureAvailablePasteboardChange(generation: generation)
        }

        let currentChangeCount = NSPasteboard.general.changeCount
        let registered = stateLock.withLock { () -> Bool in
            guard activeMode == .collecting,
                  captureGeneration == generation
            else {
                return false
            }
            if isBeforeTargetDelivery {
                copyCaptureTracker.synchronizeIfIdle(to: currentChangeCount)
            }
            copyCaptureTracker.registerCopyPress()
            captureDeadline = max(
                captureDeadline,
                ProcessInfo.processInfo.systemUptime
                    + ClipboardQueueCapturePolicy.maximumCaptureWait
            )
            return true
        }
        guard registered else {
            return
        }

        // A global NSEvent fallback is delivered after the source app in many
        // applications, so this immediate observation can capture that result.
        captureAvailablePasteboardChange(generation: generation)
        scheduleCapturePoll(generation: generation)
    }

    private func handleCopyKeyUp() {
        stateLock.withLock {
            _ = copyPressTracker.endKeyUp()
        }
    }

    private func handlePasteKeyDown(isRepeat: Bool) {
        guard !isRepeat else {
            return
        }
        let shouldProceed = stateLock.withLock { () -> Bool in
            guard activeMode == .pasting, let session = pasteSession, !session.isComplete else {
                return false
            }
            if !pastePressTracker.beginKeyDown() {
                pastePressTracker.reset()
                guard pastePressTracker.beginKeyDown() else {
                    return false
                }
            }
            return true
        }
        guard shouldProceed else {
            return
        }

        // If the user pastes faster than the fallback delay, advance the
        // previous item here. The event tap runs before the destination sees
        // this new Command-V, so it will read exactly the next payload.
        if let pending = stateLock.withLock({ pendingPasteAdvanceGeneration }) {
            advancePasteQueue(generation: pending)
        }

        let generation = stateLock.withLock { () -> Int? in
            guard activeMode == .pasting, let session = pasteSession, !session.isComplete else {
                return nil
            }
            pasteAdvanceGeneration += 1
            pendingPasteAdvanceGeneration = pasteAdvanceGeneration
            return pasteAdvanceGeneration
        }
        guard let generation else {
            return
        }
        scheduleAdvanceAfterPaste(generation: generation)
    }

    private func handlePasteKeyUp() {
        stateLock.withLock {
            _ = pastePressTracker.endKeyUp()
        }
    }

    private func handlePasteKeyDownWhileCollecting(isRepeat: Bool) {
        guard !isRepeat else {
            return
        }
        let captureGeneration = stateLock.withLock { self.captureGeneration }
        captureAvailablePasteboardChange(generation: captureGeneration)
        let currentChangeCount = NSPasteboard.general.changeCount
        let (firstPayload, totalCount, generation) = stateLock.withLock { () -> (ClipboardPayload?, Int, Int) in
            guard activeMode == .collecting, !queue.isEmpty else { return (nil, 0, 0) }
            activeMode = .pasting
            self.captureGeneration += 1
            capturePollScheduled = false
            captureDeadline = 0
            copyCaptureTracker.discardPendingCopies(
                observedChangeCount: currentChangeCount
            )
            copyPressTracker.reset()
            let session = ClipboardQueuePasteSession(queue: &queue)
            let first = session.current
            pasteSession = session
            pastePressTracker.reset()
            _ = pastePressTracker.beginKeyDown()
            pasteAdvanceGeneration += 1
            pendingPasteAdvanceGeneration = pasteAdvanceGeneration
            return (first, session.count, pasteAdvanceGeneration)
        }
        guard let firstPayload else { return }
        firstPayload.write(to: .general)
        eventHandler(.changed(mode: .pasting, count: totalCount))
        scheduleAdvanceAfterPaste(generation: generation)
    }

    private func scheduleAdvanceAfterPaste(generation: Int) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ClipboardQueuePastePolicy.advanceDelay
        ) { [weak self] in
            self?.advancePasteQueue(generation: generation)
        }
    }

    private func advancePasteQueue(generation: Int) {
        let action = stateLock.withLock { () -> (nextPayload: ClipboardPayload?, remaining: Int, shouldDeactivate: Bool)? in
            guard activeMode == .pasting,
                  pendingPasteAdvanceGeneration == generation,
                  var session = pasteSession
            else {
                return nil
            }
            pendingPasteAdvanceGeneration = nil

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

    private func captureAvailablePasteboardChange(generation: Int) {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let shouldCapture = stateLock.withLock {
            activeMode == .collecting
                && captureGeneration == generation
                && copyCaptureTracker.canConsume(changeCount: changeCount)
        }
        guard shouldCapture,
              let payload = ClipboardPayload(pasteboard: pasteboard)
        else {
            return
        }

        let outcome = stateLock.withLock { () -> (accepted: Bool, count: Int)? in
            guard activeMode == .collecting,
                  captureGeneration == generation,
                  copyCaptureTracker.consume(changeCount: changeCount)
            else {
                return nil
            }
            guard queue.count < Self.maximumItems,
                  queuedBytes + payload.byteCount <= Self.maximumBytes
            else {
                return (false, queue.count)
            }
            queue.enqueue(payload)
            queuedBytes += payload.byteCount
            return (true, queue.count)
        }
        guard let outcome else {
            return
        }
        if outcome.accepted {
            eventHandler(.changed(mode: .collecting, count: outcome.count))
        } else {
            eventHandler(.captureRejected)
        }
    }

    private func scheduleCapturePoll(generation: Int) {
        let currentChangeCount = NSPasteboard.general.changeCount
        let shouldSchedule = stateLock.withLock { () -> Bool in
            guard activeMode == .collecting,
                  captureGeneration == generation,
                  copyCaptureTracker.hasPendingCopies,
                  !capturePollScheduled
            else {
                return false
            }
            if ProcessInfo.processInfo.systemUptime >= captureDeadline {
                copyCaptureTracker.discardPendingCopies(
                    observedChangeCount: currentChangeCount
                )
                captureDeadline = 0
                return false
            }
            capturePollScheduled = true
            return true
        }
        guard shouldSchedule else {
            return
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + ClipboardQueueCapturePolicy.retryInterval
        ) { [weak self] in
            guard let self else {
                return
            }
            let shouldContinue = self.stateLock.withLock { () -> Bool in
                guard self.activeMode == .collecting,
                      self.captureGeneration == generation
                else {
                    return false
                }
                self.capturePollScheduled = false
                return true
            }
            guard shouldContinue else {
                return
            }
            self.captureAvailablePasteboardChange(generation: generation)
            self.scheduleCapturePoll(generation: generation)
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
