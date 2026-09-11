import AppKit
import AIShortcutsCore

@MainActor
final class ModelSettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private struct Draft {
        var endpoint: String
        var model: String
        var apiKey: String
    }

    private let panel: ModelSettingsPanel
    private let root = NSView()
    private let titleLabel = NSTextField(labelWithString: "Model settings")
    private let closeButton = ModelSettingsCloseButton()
    private let providerLabel = NSTextField(labelWithString: "Request style")
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let endpointLabel = NSTextField(labelWithString: "Endpoint")
    private let endpointField = ModelSettingsTextField()
    private lazy var endpointContainer = ModelSettingsFieldView(textField: endpointField)
    private let modelLabel = NSTextField(labelWithString: "Model")
    private let modelField = ModelSettingsTextField()
    private lazy var modelContainer = ModelSettingsFieldView(textField: modelField)
    private let apiKeyLabel = NSTextField(labelWithString: "API key")
    private let apiKeyField = ModelSettingsSecureTextField()
    private lazy var apiKeyContainer = ModelSettingsFieldView(textField: apiKeyField)
    private let helperLabel = NSTextField(
        labelWithString: "Stored securely in macOS Keychain · leave blank to keep the saved key."
    )
    private let helperIcon = NSImageView()
    private let validationLabel = NSTextField(labelWithString: "")
    private let cancelButton = ModelSettingsButton(title: "Cancel", target: nil, action: nil)
    private let saveButton = ModelSettingsButton(title: "Save", target: nil, action: nil)

    private var drafts: [AIProvider: Draft] = [:]
    private var selectedProvider: AIProvider = .openAICompatible
    private var onSave: ((AIProviderConfiguration, String?) -> Void)?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = ModelSettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.owner = self
        configureWindow()
        configureContent()
    }

    func show(
        configurations: [AIProvider: AIProviderConfiguration],
        selectedProvider: AIProvider,
        onSave: @escaping (AIProviderConfiguration, String?) -> Void
    ) {
        drafts = Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { provider in
            let configuration = configurations[provider]
                ?? AIProviderConfiguration.defaultConfiguration(for: provider)
            return (
                provider,
                Draft(
                    endpoint: configuration.endpoint.absoluteString,
                    model: configuration.model,
                    apiKey: ""
                )
            )
        })
        self.onSave = onSave
        self.selectedProvider = selectedProvider
        providerPopup.selectItem(at: AIProvider.allCases.firstIndex(of: selectedProvider) ?? 0)
        loadDraft(for: selectedProvider)
        validationLabel.stringValue = ""
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(endpointField)
    }

    func dismiss() {
        panel.orderOut(nil)
        onSave = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    private func configureWindow() {
        panel.delegate = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.setAccessibilityLabel("AI model settings")

        root.frame = panel.contentView?.bounds ?? .zero
        root.autoresizingMask = [.width, .height]
        ShortcutUIStyle.configurePanelSurface(
            root,
            cornerRadius: ShortcutUIStyle.explainCornerRadius
        )
        panel.contentView = root
    }

    private func configureContent() {
        configureHeader()
        configureProvider()
        configureTextFields()
        configureButtons()
        configureKeyViewLoop()

        root.addSubview(titleLabel)
        root.addSubview(closeButton)
        root.addSubview(providerLabel)
        root.addSubview(providerPopup)
        root.addSubview(endpointLabel)
        root.addSubview(endpointContainer)
        root.addSubview(modelLabel)
        root.addSubview(modelContainer)
        root.addSubview(apiKeyLabel)
        root.addSubview(apiKeyContainer)
        root.addSubview(helperIcon)
        root.addSubview(helperLabel)
        root.addSubview(validationLabel)
        root.addSubview(cancelButton)
        root.addSubview(saveButton)
    }

    private func configureHeader() {
        titleLabel.font = .systemFont(ofSize: 21, weight: .bold)
        titleLabel.textColor = ShortcutUIStyle.primaryTextColor
        titleLabel.frame = NSRect(x: 32, y: 386, width: 360, height: 26)

        closeButton.frame = NSRect(x: 580, y: 384, width: 28, height: 28)
        closeButton.target = self
        closeButton.action = #selector(cancel)
        closeButton.toolTip = "Close"
        closeButton.setAccessibilityHelp("Closes model settings without saving changes.")
    }

    private func configureProvider() {
        providerLabel.frame = NSRect(x: 32, y: 342, width: 260, height: 16)
        configureLabel(providerLabel, color: ShortcutUIStyle.primaryTextColor, size: 12.5)

        providerPopup.addItems(withTitles: AIProvider.allCases.map(\.displayName))
        providerPopup.font = .systemFont(ofSize: 13.5, weight: .semibold)
        providerPopup.frame = NSRect(x: 32, y: 298, width: 576, height: 36)
        providerPopup.appearance = NSAppearance(named: .darkAqua)
        providerPopup.contentTintColor = ShortcutUIStyle.primaryTextColor
        providerPopup.focusRingType = .none
        providerPopup.wantsLayer = true
        providerPopup.layer?.cornerRadius = 10
        providerPopup.layer?.backgroundColor = ShortcutUIStyle.raisedSurfaceColor.cgColor
        providerPopup.layer?.borderWidth = 1
        providerPopup.layer?.borderColor = ShortcutUIStyle.contentBorderColor.cgColor
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.setAccessibilityLabel("Request style")
        providerPopup.setAccessibilityHelp("Choose OpenAI-compatible Chat Completions or Anthropic Messages.")
    }

    private func configureTextFields() {
        endpointLabel.frame = NSRect(x: 32, y: 266, width: 200, height: 16)
        configureLabel(endpointLabel, color: ShortcutUIStyle.secondaryTextColor)
        endpointContainer.frame = NSRect(x: 32, y: 224, width: 576, height: 36)
        configureField(
            endpointField,
            placeholder: AIProvider.openAICompatible.endpointPlaceholder,
            accessibilityLabel: "Endpoint URL",
            accessibilityHelp: "Enter the full HTTP or HTTPS request URL for the selected provider."
        )
        endpointField.delegate = self

        modelLabel.frame = NSRect(x: 32, y: 194, width: 200, height: 16)
        configureLabel(modelLabel, color: ShortcutUIStyle.secondaryTextColor)
        modelContainer.frame = NSRect(x: 32, y: 152, width: 576, height: 36)
        configureField(
            modelField,
            placeholder: AIProvider.openAICompatible.defaultModel,
            accessibilityLabel: "Model ID",
            accessibilityHelp: "Enter the exact model identifier accepted by the selected endpoint."
        )
        modelField.delegate = self

        apiKeyLabel.frame = NSRect(x: 32, y: 122, width: 200, height: 16)
        configureLabel(apiKeyLabel, color: ShortcutUIStyle.secondaryTextColor)
        apiKeyContainer.frame = NSRect(x: 32, y: 80, width: 576, height: 36)
        configureField(
            apiKeyField,
            placeholder: "Paste a new API key",
            accessibilityLabel: "API key",
            accessibilityHelp: "The key is stored in your macOS login Keychain and is never written to the repository."
        )
        apiKeyField.delegate = self

        helperIcon.image = NSImage(
            systemSymbolName: "lock.shield.fill",
            accessibilityDescription: "Secure Keychain storage"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
        )
        helperIcon.contentTintColor = ShortcutUIStyle.successAccentColor.withAlphaComponent(0.90)
        helperIcon.imageScaling = .scaleProportionallyDown
        helperIcon.frame = NSRect(x: 32, y: 56, width: 14, height: 14)
        helperIcon.setAccessibilityLabel("Secure Keychain storage")

        helperLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        helperLabel.textColor = ShortcutUIStyle.secondaryTextColor
        helperLabel.frame = NSRect(x: 52, y: 54, width: 556, height: 18)
    }

    private func configureButtons() {
        validationLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        validationLabel.textColor = ShortcutUIStyle.warningAccentColor
        validationLabel.frame = NSRect(x: 32, y: 14, width: 374, height: 32)
        validationLabel.lineBreakMode = .byTruncatingTail
        validationLabel.isHidden = true

        cancelButton.frame = NSRect(x: 422, y: 14, width: 86, height: 32)
        configureButton(
            cancelButton,
            title: "Cancel",
            normalBackground: ShortcutUIStyle.raisedSurfaceColor,
            hoveredBackground: ShortcutUIStyle.raisedSurfaceColor.blended(withFraction: 0.12, of: .white)
                ?? ShortcutUIStyle.raisedSurfaceColor,
            tint: ShortcutUIStyle.secondaryTextColor,
            border: ShortcutUIStyle.contentBorderColor
        )
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel model settings")
        cancelButton.setAccessibilityHelp("Closes model settings without saving changes.")

        saveButton.frame = NSRect(x: 518, y: 14, width: 90, height: 32)
        configureButton(
            saveButton,
            title: "Save",
            normalBackground: ShortcutUIStyle.accentColor.withAlphaComponent(0.88),
            hoveredBackground: ShortcutUIStyle.accentColor,
            tint: ShortcutUIStyle.primaryTextColor,
            border: ShortcutUIStyle.accentColor
        )
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.setAccessibilityLabel("Save model settings")
        saveButton.setAccessibilityHelp("Saves the selected provider, endpoint, model, and optional API key.")
    }

    private func configureKeyViewLoop() {
        endpointField.nextKeyView = modelField
        modelField.nextKeyView = apiKeyField
        apiKeyField.nextKeyView = cancelButton
        cancelButton.nextKeyView = saveButton
        saveButton.nextKeyView = providerPopup
        providerPopup.nextKeyView = endpointField
    }

    private func configureLabel(
        _ label: NSTextField,
        color: NSColor,
        size: CGFloat = 12.0
    ) {
        label.font = .systemFont(ofSize: size, weight: .semibold)
        label.textColor = color
    }

    private func configureButton(
        _ button: ModelSettingsButton,
        title: String,
        normalBackground: NSColor,
        hoveredBackground: NSColor,
        tint: NSColor,
        border: NSColor
    ) {
        button.isBordered = false
        button.focusRingType = .none
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.layer?.borderWidth = 1
        button.layer?.borderColor = border.cgColor

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: tint,
                .paragraphStyle: paragraphStyle,
            ]
        )
        button.setBackgroundColors(normal: normalBackground, hovered: hoveredBackground)
    }

    private func configureField(
        _ field: NSTextField,
        placeholder: String,
        accessibilityLabel: String,
        accessibilityHelp: String
    ) {
        setPlaceholder(field, placeholder)
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityHelp(accessibilityHelp)
    }

    private func syncCurrentDraft() {
        drafts[selectedProvider] = Draft(
            endpoint: endpointField.stringValue,
            model: modelField.stringValue,
            apiKey: apiKeyField.stringValue
        )
    }

    private func loadDraft(for provider: AIProvider) {
        let draft = drafts[provider]
            ?? Draft(
                endpoint: provider.defaultEndpoint.absoluteString,
                model: provider.defaultModel,
                apiKey: ""
            )
        endpointField.stringValue = draft.endpoint
        modelField.stringValue = draft.model
        apiKeyField.stringValue = draft.apiKey
        setPlaceholder(endpointField, provider.endpointPlaceholder)
        setPlaceholder(modelField, provider.defaultModel)
        validationLabel.stringValue = ""
        validationLabel.isHidden = true
    }

    private func setPlaceholder(_ field: NSTextField, _ placeholder: String) {
        field.placeholderString = placeholder
        (field.cell as? NSTextFieldCell)?.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: ShortcutUIStyle.placeholderTextColor,
                .font: field.font ?? NSFont.systemFont(ofSize: 13.5),
            ]
        )
    }

    private func showValidation(_ message: String) {
        validationLabel.stringValue = message
        validationLabel.isHidden = false
    }

    private func setFieldFocused(_ field: NSTextField, focused: Bool) {
        if field === endpointField {
            endpointContainer.setFocused(focused)
        } else if field === modelField {
            modelContainer.setFocused(focused)
        } else if field === apiKeyField {
            apiKeyContainer.setFocused(focused)
        }
    }

    @objc private func providerChanged() {
        syncCurrentDraft()
        guard let provider = AIProvider.allCases[safe: providerPopup.indexOfSelectedItem] else {
            return
        }
        selectedProvider = provider
        loadDraft(for: provider)
    }

    @objc private func save() {
        syncCurrentDraft()
        let endpoint = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpointURL = URL(string: endpoint) else {
            showValidation("Enter a valid http(s) endpoint without embedded credentials.")
            return
        }
        let configuration = AIProviderConfiguration(
            provider: selectedProvider,
            endpoint: endpointURL,
            model: model
        )
        guard let message = configuration.validationMessage else {
            let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, key.count <= 20 {
                showValidation("The API key looks too short.")
                return
            }
            let saveHandler = onSave
            dismiss()
            saveHandler?(configuration, key.isEmpty ? nil : key)
            return
        }
        showValidation(message)
    }

    @objc private func cancel() {
        dismiss()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        setFieldFocused(field, focused: true)
    }

    func controlTextDidChange(_ notification: Notification) {
        if !validationLabel.isHidden {
            validationLabel.stringValue = ""
            validationLabel.isHidden = true
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        setFieldFocused(field, focused: false)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            save()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }
}

private final class ModelSettingsPanel: NSPanel {
    weak var owner: ModelSettingsWindowController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        owner?.dismiss()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) {
                    return true
                }
                if let responder = firstResponder as? NSTextField {
                    if let string = NSPasteboard.general.string(forType: .string) {
                        responder.stringValue = string
                        responder.delegate?.controlTextDidChange?(
                            Notification(name: NSControl.textDidChangeNotification, object: responder)
                        )
                        return true
                    }
                }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) {
                    return true
                }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) {
                    return true
                }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) {
                    return true
                }
            case "z":
                if NSApp.sendAction(Selector(("undo:")), to: nil, from: self) {
                    return true
                }
            case "w":
                owner?.dismiss()
                return true
            default:
                break
            }
        } else if flags == [.command, .shift] {
            if event.charactersIgnoringModifiers == "z" || event.charactersIgnoringModifiers == "Z" {
                if NSApp.sendAction(Selector(("redo:")), to: nil, from: self) {
                    return true
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class ModelSettingsFieldView: NSView {
    let textField: NSTextField

    init(textField: NSTextField) {
        self.textField = textField
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = ShortcutUIStyle.raisedSurfaceColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ShortcutUIStyle.contentBorderColor.cgColor

        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13.5, weight: .regular)
        textField.textColor = ShortcutUIStyle.primaryTextColor
        textField.usesSingleLineMode = true
        textField.maximumNumberOfLines = 1
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.heightAnchor.constraint(equalToConstant: 20),
        ])

        if let settingsField = textField as? ModelSettingsTextField {
            settingsField.onFocusChange = { [weak self] focused in
                self?.setFocused(focused)
            }
        } else if let secureField = textField as? ModelSettingsSecureTextField {
            secureField.onFocusChange = { [weak self] focused in
                self?.setFocused(focused)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setFocused(_ focused: Bool) {
        layer?.borderWidth = focused ? 1.5 : 1
        layer?.borderColor = focused
            ? ShortcutUIStyle.focusBorderColor.cgColor
            : ShortcutUIStyle.contentBorderColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textField)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}

private class ModelSettingsTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusChange?(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            onFocusChange?(false)
        }
        return result
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                paste(nil)
                return true
            case "c":
                copy(nil)
                return true
            case "x":
                cut(nil)
                return true
            case "a":
                selectAll(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        if let editor = currentEditor() {
            editor.paste(sender)
        } else if let string = NSPasteboard.general.string(forType: .string) {
            stringValue = string
            delegate?.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: self)
            )
        }
    }

    @objc func copy(_ sender: Any?) {
        if let editor = currentEditor() {
            editor.copy(sender)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(stringValue, forType: .string)
        }
    }

    @objc func cut(_ sender: Any?) {
        if let editor = currentEditor() {
            editor.cut(sender)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(stringValue, forType: .string)
            stringValue = ""
            delegate?.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: self)
            )
        }
    }
}

private class ModelSettingsSecureTextField: NSSecureTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusChange?(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            onFocusChange?(false)
        }
        return result
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                paste(nil)
                return true
            case "a":
                selectAll(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        if let editor = currentEditor() {
            editor.paste(sender)
        } else if let string = NSPasteboard.general.string(forType: .string) {
            stringValue = string
            delegate?.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: self)
            )
        }
    }
}

private final class ModelSettingsCloseButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isBordered = false
        focusRingType = .none
        image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close model settings"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        )
        contentTintColor = ShortcutUIStyle.secondaryTextColor
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = ShortcutUIStyle.primaryTextColor
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = ShortcutUIStyle.secondaryTextColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class ModelSettingsButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var normalBackgroundColor = NSColor.clear
    private var hoveredBackgroundColor = NSColor.clear

    func setBackgroundColors(normal: NSColor, hovered: NSColor) {
        normalBackgroundColor = normal
        hoveredBackgroundColor = hovered
        updateBackground()
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = (isHovered ? hoveredBackgroundColor : normalBackgroundColor).cgColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
