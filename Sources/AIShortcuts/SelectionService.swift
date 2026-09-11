import AppKit
import ApplicationServices
import AIShortcutsCore
import AIShortcutsRendering
import Foundation

@MainActor
struct SelectionSnapshot {
    let text: String
    let processIdentifier: pid_t
    let application: NSRunningApplication?
    let accessibilityElement: AXUIElement?
}

@MainActor
final class SelectionService {
    func captureSelection(preserveClipboard: Bool = false) async -> SelectionSnapshot? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let processIdentifier = frontmost?.processIdentifier ?? 0

        if let element = focusedElement(for: processIdentifier),
           let selectedText = selectedText(from: element),
           !selectedText.isEmpty
        {
            return SelectionSnapshot(
                text: selectedText,
                processIdentifier: processIdentifier,
                application: frontmost,
                accessibilityElement: element
            )
        }

        guard let copiedText = await copyUsingKeyboard(
            preserveClipboard: preserveClipboard,
            expectedProcessIdentifier: processIdentifier
        ), !copiedText.isEmpty else {
            return nil
        }
        return SelectionSnapshot(
            text: copiedText,
            processIdentifier: processIdentifier,
            application: frontmost,
            accessibilityElement: nil
        )
    }

    func reactivate(_ snapshot: SelectionSnapshot) {
        snapshot.application?.activate(options: [.activateIgnoringOtherApps])
    }

    func placeOnClipboard(_ text: String) {
        placeOnClipboard(
            RichClipboardPayload(
                plainText: text,
                htmlData: nil,
                rtfData: nil,
                rtfdData: nil
            )
        )
    }

    func placeOnClipboard(_ payload: RichClipboardPayload) {
        payload.write(to: NSPasteboard.general)
    }

    func insertText(
        _ text: String,
        into application: NSRunningApplication?
    ) async -> Bool {
        guard let application else {
            return false
        }
        await waitForShortcutModifiersToRelease()

        let pasteboard = NSPasteboard.general
        let backup = PasteboardBackup(pasteboard: pasteboard)
        application.activate(options: [.activateIgnoringOtherApps])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier
            {
                break
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier
        else {
            return false
        }

        placeOnClipboard(text)
        try? await Task.sleep(nanoseconds: 25_000_000)
        await postKey(keyCode: 9, flags: .maskCommand) // V
        // Most applications consume Paste synchronously, but a short grace
        // period protects controls that read the pasteboard on the next turn.
        try? await Task.sleep(nanoseconds: 220_000_000)
        backup.restore(to: pasteboard)
        return true
    }

    func replaceIfUnchanged(_ snapshot: SelectionSnapshot, with result: String) async -> Bool {
        await replaceIfUnchanged(
            snapshot,
            with: RichClipboardPayload(
                plainText: result,
                htmlData: nil,
                rtfData: nil,
                rtfdData: nil
            ),
            preferAccessibility: true
        )
    }

    func replaceIfUnchanged(
        _ snapshot: SelectionSnapshot,
        with payload: RichClipboardPayload,
        preferAccessibility: Bool = true
    ) async -> Bool {
        placeOnClipboard(payload)

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmostPID == snapshot.processIdentifier else {
            return false
        }

        if preferAccessibility, let element = snapshot.accessibilityElement {
            if let currentText = selectedText(from: element) {
                guard SelectionReplacementPolicy.shouldReplace(
                    originalText: snapshot.text,
                    currentText: currentText,
                    originalProcessIdentifier: snapshot.processIdentifier,
                    frontmostProcessIdentifier: frontmostPID
                ) else {
                    return false
                }
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(
                    element,
                    kAXSelectedTextAttribute as CFString,
                    &settable
                ) == .success,
                   settable.boolValue,
                   AXUIElementSetAttributeValue(
                       element,
                       kAXSelectedTextAttribute as CFString,
                       payload.plainText as CFTypeRef
                   ) == .success
                {
                    return true
                }
            }
            // Some browser/Electron controls expose the selection during
            // capture but not later. Fall through to a fresh Command-C check.
        }

        let currentText = await copyUsingKeyboard(
            preserveClipboard: false,
            expectedProcessIdentifier: snapshot.processIdentifier
        )
        let stillMatches = SelectionReplacementPolicy.shouldReplace(
            originalText: snapshot.text,
            currentText: currentText,
            originalProcessIdentifier: snapshot.processIdentifier,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
        placeOnClipboard(payload)
        guard stillMatches else {
            return false
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == snapshot.processIdentifier
        else {
            return false
        }
        await postKey(keyCode: 9, flags: .maskCommand) // V
        return true
    }

    private func focusedElement(for processIdentifier: pid_t) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
            let value
        {
            return (value as! AXUIElement)
        }

        guard processIdentifier > 0 else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(processIdentifier)
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
            let value
        {
            return (value as! AXUIElement)
        }

        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
            let windowValue
        {
            let windowElement = windowValue as! AXUIElement
            if AXUIElementCopyAttributeValue(
                windowElement,
                kAXFocusedUIElementAttribute as CFString,
                &value
            ) == .success,
                let value
            {
                return (value as! AXUIElement)
            }
            return windowElement
        }

        return nil
    }

    private func selectedText(from element: AXUIElement) -> String? {
        if let directText = extractSelectedText(from: element) {
            return directText
        }

        // Chromium and WebKit browsers (e.g. Safari, Arc, Chrome) or document
        // views often attach the selected text attribute to an enclosing container
        // (such as an AXWebArea, AXScrollArea, or AXDocument) rather than the
        // clicked static text node. Walk up the ancestor chain to find it.
        var current = element
        for _ in 0..<6 {
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                current,
                kAXParentAttribute as CFString,
                &parentValue
            ) == .success,
                let parentValue
            else {
                break
            }
            let parent = (parentValue as! AXUIElement)
            if let parentText = extractSelectedText(from: parent) {
                return parentText
            }
            current = parent
        }

        return nil
    }

    private func extractSelectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success,
           let selected = value as? String,
           !selected.isEmpty
        {
            return selected
        }

        // Chromium and some Electron controls expose a range and the full
        // value, but not kAXSelectedTextAttribute itself.
        var rangeReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeReference
        ) == .success,
            let rangeReference,
            CFGetTypeID(rangeReference) == AXValueGetTypeID()
        else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(
            rangeReference as! AXValue,
            .cfRange,
            &range
        ),
            range.location >= 0,
            range.length > 0
        else {
            return nil
        }

        var fullValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &fullValue
        ) == .success,
            let fullText = fullValue as? String
        else {
            return nil
        }
        let nsText = fullText as NSString
        guard range.location + range.length <= nsText.length else {
            return nil
        }
        return nsText.substring(
            with: NSRange(location: range.location, length: range.length)
        )
    }

    private func copyUsingKeyboard(
        preserveClipboard: Bool,
        expectedProcessIdentifier: pid_t
    ) async -> String? {
        await waitForShortcutModifiersToRelease()

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == expectedProcessIdentifier
        else {
            return nil
        }
        // Let the source application finish handling the Carbon hotkey-release
        // event before asking it to process a synthetic Copy.
        try? await Task.sleep(nanoseconds: 20_000_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == expectedProcessIdentifier
        else {
            return nil
        }

        let pasteboard = NSPasteboard.general
        // Always back up the pasteboard so we can restore it if copying fails,
        // preventing probe marker strings from corrupting user clipboard history.
        let backup = PasteboardBackup(pasteboard: pasteboard)
        var shouldRestoreBackup = true
        defer {
            if shouldRestoreBackup {
                backup.restore(to: pasteboard)
            }
        }

        let marker = "com.susanawang.aishortcuts.copy-probe.\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)
        let markerChangeCount = pasteboard.changeCount
        await postKey(keyCode: 8, flags: .maskCommand) // C

        // Poll for up to 525ms (35 * 15ms) to accommodate multi-process IPC
        // latency in web browsers (Safari, Chrome) and Electron apps (ChatGPT, Slack).
        for attempt in 0..<35 {
            if pasteboard.changeCount != markerChangeCount {
                let copied = pasteboard.string(forType: .string)
                    ?? (pasteboard.readObjects(forClasses: [NSString.self], options: nil)?.first as? String)
                if let copied,
                   copied != marker,
                   !copied.isEmpty
                {
                    shouldRestoreBackup = preserveClipboard
                    return copied
                }
            }
            if (attempt == 8 || attempt == 18),
               NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == expectedProcessIdentifier
            {
                await postKey(keyCode: 8, flags: .maskCommand)
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return nil
    }

    private func waitForShortcutModifiersToRelease() async {
        let shortcutModifiers: CGEventFlags = [
            .maskCommand,
            .maskAlternate,
            .maskControl,
        ]
        // Allow up to 250ms for natural user key release without ever aborting early.
        for _ in 0..<25 {
            if Task.isCancelled {
                return
            }
            let current = CGEventSource.flagsState(.combinedSessionState)
            if current.intersection(shortcutModifiers).isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags) async {
        // Use a private event source (stateID: -1) so the synthetic event is isolated
        // from physical modifier key states in combinedSessionState / hidSystemState.
        let source = CGEventSource(stateID: CGEventSourceStateID(rawValue: -1)!)
            ?? CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return
        }
        down.flags = flags
        up.flags = flags

        down.post(tap: .cghidEventTap)
        // Brief 12ms pause ensures target application event loops (e.g. Chromium / WebKit)
        // properly register the key-down before receiving the key-up.
        try? await Task.sleep(nanoseconds: 12_000_000)
        up.post(tap: .cghidEventTap)
    }
}

private struct PasteboardBackup {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [:]) { values, type in
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}
