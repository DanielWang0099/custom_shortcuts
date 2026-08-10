import AppKit
import ApplicationServices
import AIShortcutsCore
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

        if let element = focusedElement(),
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func insertText(
        _ text: String,
        into application: NSRunningApplication?
    ) async -> Bool {
        guard let application,
              await waitForShortcutModifiersToRelease()
        else {
            return false
        }

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
        postKey(keyCode: 9, flags: .maskCommand) // V
        // Most applications consume Paste synchronously, but a short grace
        // period protects controls that read the pasteboard on the next turn.
        try? await Task.sleep(nanoseconds: 220_000_000)
        backup.restore(to: pasteboard)
        return true
    }

    func replaceIfUnchanged(_ snapshot: SelectionSnapshot, with result: String) async -> Bool {
        placeOnClipboard(result)

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmostPID == snapshot.processIdentifier else {
            return false
        }

        if let element = snapshot.accessibilityElement {
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
                       result as CFTypeRef
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
        placeOnClipboard(result)
        guard stillMatches else {
            return false
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == snapshot.processIdentifier
        else {
            return false
        }
        postKey(keyCode: 9, flags: .maskCommand) // V
        return true
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
            let value
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func selectedText(from element: AXUIElement) -> String? {
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
        guard await waitForShortcutModifiersToRelease(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == expectedProcessIdentifier
        else {
            return nil
        }
        // Let the source application finish handling the Carbon hotkey-release
        // event before asking it to process a synthetic Copy.
        try? await Task.sleep(nanoseconds: 25_000_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == expectedProcessIdentifier
        else {
            return nil
        }

        let pasteboard = NSPasteboard.general
        let backup = preserveClipboard ? PasteboardBackup(pasteboard: pasteboard) : nil
        defer {
            backup?.restore(to: pasteboard)
        }
        let marker = "com.susanawang.aishortcuts.copy-probe.\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)
        let markerChangeCount = pasteboard.changeCount
        postKey(keyCode: 8, flags: .maskCommand) // C

        for attempt in 0..<15 {
            if pasteboard.changeCount != markerChangeCount,
               let copied = pasteboard.string(forType: .string),
               copied != marker
            {
                return copied
            }
            if attempt == 7,
               NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == expectedProcessIdentifier
            {
                postKey(keyCode: 8, flags: .maskCommand)
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return nil
    }

    private func waitForShortcutModifiersToRelease() async -> Bool {
        let shortcutModifiers: CGEventFlags = [
            .maskCommand,
            .maskAlternate,
            .maskControl,
        ]
        for _ in 0..<30 {
            if Task.isCancelled {
                return false
            }
            let current = CGEventSource.flagsState(.combinedSessionState)
            if current.intersection(shortcutModifiers).isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
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
