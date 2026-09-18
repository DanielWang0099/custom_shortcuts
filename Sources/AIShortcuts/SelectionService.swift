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
    let selectionElement: AXUIElement?
    let focusedElement: AXUIElement?
}

private struct AccessibilitySelection {
    let text: String
    let element: AXUIElement
}

@MainActor
final class SelectionService {
    func captureSelection(preserveClipboard: Bool = false) async -> SelectionSnapshot? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let processIdentifier = frontmost?.processIdentifier ?? 0
        let focusedElement = focusedElement(for: processIdentifier)
        let preferKeyboardCopy = SelectionCapturePolicy.shouldPreferKeyboardCopy(
            role: focusedElement.flatMap {
                attributeString(kAXRoleAttribute, from: $0)
            },
            applicationBundleIdentifier: frontmost?.bundleIdentifier
        )

        if preferKeyboardCopy,
           let copiedText = await copyUsingKeyboard(
               preserveClipboard: preserveClipboard,
               expectedProcessIdentifier: processIdentifier
           )
        {
            return SelectionSnapshot(
                text: copiedText,
                processIdentifier: processIdentifier,
                application: frontmost,
                selectionElement: nil,
                focusedElement: focusedElement
            )
        }

        if let focusedElement,
           let selection = accessibilitySelection(from: focusedElement),
           SelectionCapturePolicy.containsMeaningfulText(selection.text)
        {
            return SelectionSnapshot(
                text: selection.text,
                processIdentifier: processIdentifier,
                application: frontmost,
                selectionElement: selection.element,
                focusedElement: focusedElement
            )
        }

        guard !preferKeyboardCopy else {
            return nil
        }
        guard let copiedText = await copyUsingKeyboard(
            preserveClipboard: preserveClipboard,
            expectedProcessIdentifier: processIdentifier
        ) else {
            return nil
        }
        return SelectionSnapshot(
            text: copiedText,
            processIdentifier: processIdentifier,
            application: frontmost,
            selectionElement: nil,
            focusedElement: focusedElement
        )
    }

    func reactivate(_ snapshot: SelectionSnapshot) async -> Bool {
        guard let application = snapshot.application else {
            return false
        }
        application.activate(options: [.activateIgnoringOtherApps])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == snapshot.processIdentifier
            {
                break
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == snapshot.processIdentifier
        else {
            return false
        }
        guard let focusedElement = snapshot.focusedElement else {
            return false
        }
        if SelectionCapturePolicy.shouldRestoreFocusUsingAccessibility(
            role: attributeString(kAXRoleAttribute, from: focusedElement),
            applicationBundleIdentifier: application.bundleIdentifier
        ) {
            _ = AXUIElementSetAttributeValue(
                focusedElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
        for attempt in 0..<SelectionFocusVerificationPolicy.maximumAttempts {
            let focusMatches = focusedElementMatches(snapshot)
            if focusMatches {
                return true
            }
            guard SelectionFocusVerificationPolicy.shouldRetry(
                afterAttempt: attempt,
                focusedElementMatches: focusMatches
            ) else {
                return false
            }
            try? await Task.sleep(
                nanoseconds: SelectionFocusVerificationPolicy.retryIntervalNanoseconds
            )
        }
        return false
    }

    @discardableResult
    func placeOnClipboard(_ text: String) -> Bool {
        placeOnClipboard(
            RichClipboardPayload(
                plainText: text,
                htmlData: nil,
                rtfData: nil,
                rtfdData: nil
            )
        )
    }

    @discardableResult
    func placeOnClipboard(_ payload: RichClipboardPayload) -> Bool {
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
        guard let backup = await PasteboardBackup.capture(from: pasteboard) else {
            return false
        }
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

        guard placeOnClipboard(text) else {
            return false
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
        guard await postKey(keyCode: 9, flags: .maskCommand) else { // V
            _ = backup.restore(to: pasteboard)
            return false
        }
        // Most applications consume Paste synchronously, but a short grace
        // period protects controls that read the pasteboard on the next turn.
        try? await Task.sleep(nanoseconds: 220_000_000)
        return backup.restore(to: pasteboard)
    }

    func replaceIfUnchanged(
        _ snapshot: SelectionSnapshot,
        with result: String
    ) async -> SelectionDeliveryOutcome {
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
    ) async -> SelectionDeliveryOutcome {
        guard placeOnClipboard(payload) else {
            return SelectionDeliveryPolicy.outcome(
                clipboardWriteSucceeded: false,
                replacementEligible: false,
                replacementDispatched: false,
                verification: .indeterminate
            )
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmostPID == snapshot.processIdentifier else {
            return .copied
        }

        if preferAccessibility, let element = snapshot.selectionElement {
            if let currentText = extractSelectedText(from: element) {
                let focusMatches = focusedElementMatches(snapshot)
                guard SelectionReplacementPolicy.shouldReplace(
                    originalText: snapshot.text,
                    currentText: currentText,
                    originalProcessIdentifier: snapshot.processIdentifier,
                    frontmostProcessIdentifier: frontmostPID,
                    focusedElementMatches: focusMatches
                ) else {
                    return .copied
                }
                var settable = DarwinBoolean(false)
                let settableResult = AXUIElementIsAttributeSettable(
                    element,
                    kAXSelectedTextAttribute as CFString,
                    &settable
                )
                if SelectionReplacementPolicy.shouldUseDirectAccessibilityReplacement(
                    role: attributeString(kAXRoleAttribute, from: element),
                    selectedTextSettable: settableResult == .success && settable.boolValue,
                    applicationBundleIdentifier: snapshot.application?.bundleIdentifier
                ),
                   AXUIElementSetAttributeValue(
                       element,
                       kAXSelectedTextAttribute as CFString,
                       payload.plainText as CFTypeRef
                   ) == .success
                {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    let verification = SelectionReplacementPolicy.verifyReplacement(
                        originalText: snapshot.text,
                        resultText: payload.plainText,
                        observedText: extractSelectedText(from: element),
                        originalProcessIdentifier: snapshot.processIdentifier,
                        frontmostProcessIdentifier: NSWorkspace.shared
                            .frontmostApplication?.processIdentifier,
                        focusedElementMatches: focusedElementMatches(snapshot)
                    )
                    switch verification {
                    case .verified, .indeterminate:
                        return SelectionDeliveryPolicy.outcome(
                            clipboardWriteSucceeded: true,
                            replacementEligible: true,
                            replacementDispatched: true,
                            verification: verification
                        )
                    case .unchanged:
                        break
                    }
                }
            }
            // Some browser/Electron controls expose the selection during
            // capture but not later. Fall through to a fresh Command-C check.
        }

        guard focusedElementMatches(snapshot) else {
            return .copied
        }
        let currentText = await copyUsingKeyboard(
            preserveClipboard: false,
            expectedProcessIdentifier: snapshot.processIdentifier
        )
        let focusMatchesAfterCopy = focusedElementMatches(snapshot)
        let stillMatches = SelectionReplacementPolicy.shouldReplace(
            originalText: snapshot.text,
            currentText: currentText,
            originalProcessIdentifier: snapshot.processIdentifier,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            focusedElementMatches: focusMatchesAfterCopy
        )
        guard placeOnClipboard(payload) else {
            return .clipboardFailed
        }
        guard stillMatches else {
            return .copied
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == snapshot.processIdentifier,
              focusedElementMatches(snapshot)
        else {
            return .copied
        }
        guard await postKey(keyCode: 9, flags: .maskCommand) else { // V
            return .copied
        }
        try? await Task.sleep(nanoseconds: 120_000_000)

        let verification = SelectionReplacementPolicy.verifyReplacement(
            originalText: snapshot.text,
            resultText: payload.plainText,
            observedText: snapshot.selectionElement.flatMap(extractSelectedText),
            originalProcessIdentifier: snapshot.processIdentifier,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            focusedElementMatches: focusedElementMatches(snapshot)
        )
        return SelectionDeliveryPolicy.outcome(
            clipboardWriteSucceeded: true,
            replacementEligible: true,
            replacementDispatched: true,
            verification: verification
        )
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

    private func focusedElementMatches(_ snapshot: SelectionSnapshot) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == snapshot.processIdentifier
        else {
            return false
        }
        guard let capturedElement = snapshot.focusedElement else {
            return false
        }
        guard let currentElement = focusedElement(for: snapshot.processIdentifier) else {
            return false
        }
        return CFEqual(capturedElement, currentElement)
    }

    private func accessibilitySelection(
        from element: AXUIElement
    ) -> AccessibilitySelection? {
        if let directText = extractSelectedText(from: element) {
            return AccessibilitySelection(text: directText, element: element)
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
                return AccessibilitySelection(text: parentText, element: parent)
            }
            current = parent
        }

        return nil
    }

    private func attributeString(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func extractSelectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success,
           let selected = value as? String,
           SelectionCapturePolicy.containsMeaningfulText(selected)
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
        let selected = nsText.substring(
            with: NSRange(location: range.location, length: range.length)
        )
        return SelectionCapturePolicy.containsMeaningfulText(selected) ? selected : nil
    }

    private func copyUsingKeyboard(
        preserveClipboard: Bool,
        expectedProcessIdentifier: pid_t
    ) async -> String? {
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
        let backup: PasteboardBackup?
        if preserveClipboard {
            guard let captured = await PasteboardBackup.capture(from: pasteboard) else {
                return nil
            }
            backup = captured
        } else {
            backup = nil
        }
        // Observe Copy without placing a probe value on the user's clipboard.
        // Chromium may vend copied text lazily; reading that value in-process can
        // block AppKit for minutes, so a bounded helper process performs the read.
        var examinedChangeCount = pasteboard.changeCount
        guard await postKey(keyCode: 8, flags: .maskCommand) else { // C
            _ = backup?.restore(to: pasteboard)
            return nil
        }
        // Poll long enough for multi-process IPC in browsers and Electron apps.
        // Each newly published pasteboard generation gets one bounded plain-text read.
        var capturedText: String?
        for attempt in 0..<35 {
            guard !Task.isCancelled else {
                break
            }
            let currentChangeCount = pasteboard.changeCount
            if currentChangeCount != examinedChangeCount {
                examinedChangeCount = currentChangeCount
                if let copied = await stableGeneralPasteboardPlainText(
                    generation: currentChangeCount,
                    pasteboard: pasteboard
                )
                {
                    capturedText = copied
                    break
                }
            }
            if (attempt == 8 || attempt == 18),
               NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == expectedProcessIdentifier
            {
                _ = await postKey(keyCode: 8, flags: .maskCommand)
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        guard backup?.restore(to: pasteboard) ?? true else {
            return nil
        }
        return capturedText
    }

    private func stableGeneralPasteboardPlainText(
        generation: Int,
        pasteboard: NSPasteboard
    ) async -> String? {
        guard let firstRead = await readGeneralPasteboardPlainText(),
              SelectionCapturePolicy.containsMeaningfulText(firstRead)
        else {
            return nil
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
        guard pasteboard.changeCount == generation,
              let secondRead = await readGeneralPasteboardPlainText(),
              pasteboard.changeCount == generation,
              secondRead == firstRead
        else {
            return nil
        }
        return firstRead
    }

    private func readGeneralPasteboardPlainText() async -> String? {
        guard let data = await BoundedProcessOutput.capture(
            executableURL: URL(fileURLWithPath: "/usr/bin/pbpaste"),
            arguments: ["-Prefer", "txt"],
            timeoutNanoseconds: 650_000_000
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags) async -> Bool {
        // Use a private event source so the synthetic event is isolated
        // from physical modifier key states in combinedSessionState / hidSystemState.
        // If the private source is unavailable, wait for the physical modifiers
        // before falling back to the shared HID event source.
        let source: CGEventSource?
        if let isolatedSource = CGEventSource(stateID: .privateState) {
            source = isolatedSource
        } else {
            await waitForShortcutModifiersToRelease()
            source = CGEventSource(stateID: .hidSystemState)
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        down.flags = flags
        up.flags = flags

        down.post(tap: .cghidEventTap)
        // Brief 12ms pause ensures target application event loops (e.g. Chromium / WebKit)
        // properly register the key-down before receiving the key-up.
        try? await Task.sleep(nanoseconds: 12_000_000)
        up.post(tap: .cghidEventTap)
        return true
    }
}

private struct PasteboardBackup {
    private let snapshot: ClipboardSnapshot

    @MainActor
    static func capture(from pasteboard: NSPasteboard) async -> PasteboardBackup? {
        guard let executableURL = Bundle.main.executableURL else {
            return nil
        }
        let generation = pasteboard.changeCount
        guard let data = await BoundedProcessOutput.capture(
            executableURL: executableURL,
            arguments: ["--pasteboard-snapshot", pasteboard.name.rawValue],
            timeoutNanoseconds: 1_250_000_000
        ), pasteboard.changeCount == generation,
           let snapshot = ClipboardSnapshot.decode(data)
        else {
            return nil
        }
        return PasteboardBackup(snapshot: snapshot)
    }

    @MainActor
    @discardableResult
    func restore(to pasteboard: NSPasteboard) -> Bool {
        snapshot.restore(to: pasteboard)
    }
}
