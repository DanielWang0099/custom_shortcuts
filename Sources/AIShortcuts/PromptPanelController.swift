import AppKit

@MainActor
final class PromptPanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private let panel: InputPanel
    private let titleLabel: NSTextField
    private let hintLabel: NSTextField
    private let inputSurface: NSView
    private let textField: NSTextField
    private let submitButton: NSButton
    private var completion: ((String?) -> Void)?
    private var finished = false
    private var allowsEmptySubmission = false

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = InputPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 108),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        titleLabel = NSTextField(labelWithString: "")
        hintLabel = NSTextField(labelWithString: "Return to run  ·  Esc to close")
        inputSurface = NSView(frame: NSRect(x: 12, y: 12, width: 476, height: 56))
        textField = NSTextField(frame: NSRect(x: 16, y: 16, width: 398, height: 24))
        submitButton = NSButton(frame: NSRect(x: 426, y: 10, width: 36, height: 36))
        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel("Shortcut instruction")

        let background = NSView(frame: panel.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        ShortcutUIStyle.configurePanelSurface(
            background,
            cornerRadius: ShortcutUIStyle.promptCornerRadius
        )

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = ShortcutUIStyle.primaryTextColor
        titleLabel.frame = NSRect(x: 18, y: 78, width: 230, height: 18)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityLabel("Shortcut")

        hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hintLabel.textColor = ShortcutUIStyle.secondaryTextColor
        hintLabel.alignment = .right
        hintLabel.frame = NSRect(x: 250, y: 79, width: 232, height: 16)

        ShortcutUIStyle.configureContentSurface(
            inputSurface,
            cornerRadius: ShortcutUIStyle.inputCornerRadius
        )

        textField.delegate = self
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 15.5, weight: .regular)
        textField.textColor = ShortcutUIStyle.primaryTextColor
        textField.placeholderString = nil
        textField.maximumNumberOfLines = 1
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.usesSingleLineMode = true
        textField.setAccessibilityLabel("Instruction")
        textField.setAccessibilityHelp("Type an instruction, then press Return. Press Escape to cancel.")

        submitButton.isBordered = false
        submitButton.focusRingType = .none
        submitButton.imagePosition = .imageOnly
        submitButton.imageScaling = .scaleProportionallyDown
        submitButton.image = NSImage(
            systemSymbolName: "arrow.up",
            accessibilityDescription: "Run shortcut"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        )
        submitButton.contentTintColor = ShortcutUIStyle.shellColor
        submitButton.wantsLayer = true
        submitButton.layer?.cornerRadius = 18
        submitButton.layer?.backgroundColor = ShortcutUIStyle.primaryTextColor.cgColor
        submitButton.target = self
        submitButton.action = #selector(submitFromButton)
        submitButton.setAccessibilityLabel("Run shortcut")
        submitButton.setAccessibilityHelp("Runs the shortcut with the current instruction.")

        inputSurface.addSubview(textField)
        inputSurface.addSubview(submitButton)
        background.addSubview(titleLabel)
        background.addSubview(hintLabel)
        background.addSubview(inputSurface)
        panel.contentView = background
    }

    func show(
        title: String,
        placeholder: String,
        allowsEmptySubmission: Bool = false,
        completion: @escaping (String?) -> Void
    ) {
        self.completion = completion
        self.allowsEmptySubmission = allowsEmptySubmission
        finished = false
        titleLabel.stringValue = title
        textField.placeholderString = nil
        (textField.cell as? NSTextFieldCell)?.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15.5),
                .foregroundColor: ShortcutUIStyle.placeholderTextColor,
            ]
        )
        textField.stringValue = ""
        setInputFocused(true)
        updateSubmitButton()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: mouse.x - 250, y: mouse.y - 54, width: 500, height: 108)
        let targetX = min(
            max(mouse.x - panel.frame.width / 2, visible.minX + 8),
            visible.maxX - panel.frame.width - 8
        )
        let proposedY = mouse.y - 130
        let targetY = min(
            max(proposedY, visible.minY + 8),
            visible.maxY - panel.frame.height - 8
        )
        panel.setFrameOrigin(NSPoint(x: targetX, y: targetY))

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        cancel()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        setInputFocused(true)
    }

    func controlTextDidChange(_ notification: Notification) {
        updateSubmitButton()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        setInputFocused(false)
    }

    @objc private func submitFromButton() {
        submit()
    }

    private func submit() {
        let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty, !allowsEmptySubmission {
            finish(nil)
        } else {
            finish(value)
        }
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ value: String?) {
        guard !finished else {
            return
        }
        finished = true
        panel.orderOut(nil)
        let callback = completion
        completion = nil
        callback?(value)
    }

    private func setInputFocused(_ focused: Bool) {
        inputSurface.layer?.borderWidth = focused ? 1.5 : 1
        inputSurface.layer?.borderColor = focused
            ? ShortcutUIStyle.focusBorderColor.cgColor
            : ShortcutUIStyle.contentBorderColor.cgColor
    }

    private func updateSubmitButton() {
        let hasInput = !textField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        submitButton.isEnabled = allowsEmptySubmission || hasInput
        submitButton.alphaValue = submitButton.isEnabled ? 1 : 0.34
    }
}

private final class InputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
