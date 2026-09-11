import AppKit
import AIShortcutsCore
import QuartzCore

private enum InsertPanelMode {
    case lookup
    case browse
    case create
    case modify
    case delete
}

@MainActor
final class InsertPanelController: NSObject, NSTextFieldDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    typealias CreateHandler = (String, String) throws -> [InsertEntry]
    typealias UpdateHandler = (UUID, String, String) throws -> [InsertEntry]
    typealias DeleteHandler = (UUID) throws -> [InsertEntry]

    private let panel: InsertPanel
    private let root = FlippedView()
    private let titleLabel = NSTextField(labelWithString: "Insert")
    private let contextLabel = NSTextField(labelWithString: "/new · /modify · /delete")
    private let backButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    private let lookupSurface = NSView()
    private let libraryRevealButton = ThinLibraryButton()
    private let lookupField = NSTextField()
    private let lookupButton = NSButton()

    private let createSurface = NSView()
    private let keySurface = NSView()
    private let valueSurface = NSView()
    private let keyField = NSTextField()
    private let arrowImageView = NSImageView()
    private let valueField = NSTextField()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let rowsView = FlippedView()

    private var mode: InsertPanelMode = .lookup
    private var entries: [InsertEntry] = []
    private var onLookup: ((String) -> Void)?
    private var onCreate: CreateHandler?
    private var onUpdate: UpdateHandler?
    private var onDelete: DeleteHandler?
    private var isResolving = false

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = InsertPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 126),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
        configureSharedChrome()
        configureLookup()
        configureCreate()
        configureManagement()
        setMode(.lookup, animated: false)
    }

    func show(
        entries: [InsertEntry],
        onLookup: @escaping (String) -> Void,
        onCreate: @escaping CreateHandler,
        onUpdate: @escaping UpdateHandler,
        onDelete: @escaping DeleteHandler
    ) {
        self.entries = entries
        self.onLookup = onLookup
        self.onCreate = onCreate
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        setResolving(false)
        lookupField.stringValue = ""
        keyField.stringValue = ""
        valueField.stringValue = ""
        searchField.stringValue = ""
        statusLabel.stringValue = ""
        setMode(.lookup, animated: false)
        positionOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(lookupField)
        assert(lookupField.isEditable, "Insert lookup must be editable whenever the panel opens.")
    }

    func setResolving(_ resolving: Bool) {
        isResolving = resolving
        lookupField.isEditable = !resolving
        lookupButton.isEnabled = !resolving
        lookupButton.alphaValue = resolving ? 0.42 : 1
        contextLabel.stringValue = resolving
            ? "Finding the best match…"
            : "/new · /modify · /delete"
    }

    func showLookupError(_ message: String) {
        setResolving(false)
        statusLabel.textColor = ShortcutUIStyle.warningAccentColor
        statusLabel.stringValue = message
        statusLabel.alphaValue = 0

        var targetFrame = panel.frame
        targetFrame.origin.y += targetFrame.height - 148
        targetFrame.size.height = 148
        layoutCurrentMode(height: 148)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
            statusLabel.animator().alphaValue = 1
        }
        panel.makeFirstResponder(lookupField)
    }

    func dismiss() {
        panel.orderOut(nil)
        setResolving(false)
        onLookup = nil
        onCreate = nil
        onUpdate = nil
        onDelete = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isResolving else {
            return
        }
        dismiss()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }
        if field === lookupField {
            clearLookupStatus()
            switch field.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            {
            case "/new":
                setMode(.create, animated: true)
            case "/modify":
                setMode(.modify, animated: true)
            case "/delete":
                setMode(.delete, animated: true)
            default:
                updateLookupButton()
            }
        } else if field === searchField {
            rebuildRows()
        } else if field === keyField || field === valueField {
            updateSaveButton()
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }
        if field === keyField {
            setFieldSurface(keySurface, focused: true)
        } else if field === valueField {
            setFieldSurface(valueSurface, focused: true)
        } else if field === lookupField {
            setFieldSurface(lookupSurface, focused: true)
        } else if field === searchField {
            setSearchFieldFocused(true)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }
        if field === keyField {
            setFieldSurface(keySurface, focused: false)
        } else if field === valueField {
            setFieldSurface(valueSurface, focused: false)
        } else if field === lookupField {
            setFieldSurface(lookupSurface, focused: false)
        } else if field === searchField {
            setSearchFieldFocused(false)
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        if control === lookupField {
            submitLookup()
            return true
        }
        if control === keyField {
            panel.makeFirstResponder(valueField)
            return true
        }
        if control === valueField {
            saveNewEntry()
            return true
        }
        return false
    }

    private func configureWindow() {
        panel.delegate = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel("Insert library")

        root.frame = panel.contentView?.bounds ?? .zero
        root.autoresizingMask = [.width, .height]
        ShortcutUIStyle.configurePanelSurface(
            root,
            cornerRadius: ShortcutUIStyle.promptCornerRadius
        )
        panel.contentView = root
    }

    private func configureSharedChrome() {
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = ShortcutUIStyle.primaryTextColor

        contextLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        contextLabel.textColor = ShortcutUIStyle.secondaryTextColor
        contextLabel.alignment = .right

        backButton.isBordered = false
        backButton.image = NSImage(
            systemSymbolName: "chevron.left",
            accessibilityDescription: "Back to Insert"
        )
        backButton.contentTintColor = ShortcutUIStyle.secondaryTextColor
        backButton.target = self
        backButton.action = #selector(backToLookup)

        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.textColor = ShortcutUIStyle.warningAccentColor
        statusLabel.lineBreakMode = .byTruncatingTail

        root.addSubview(titleLabel)
        root.addSubview(contextLabel)
        root.addSubview(backButton)
        root.addSubview(statusLabel)
    }

    private func configureLookup() {
        ShortcutUIStyle.configureContentSurface(
            lookupSurface,
            cornerRadius: ShortcutUIStyle.inputCornerRadius
        )
        configureTextField(
            lookupField,
            placeholder: "e.g. email, phone, university",
            accessibilityLabel: "Insertion key"
        )
        lookupField.delegate = self

        configureCircleButton(
            lookupButton,
            symbol: "arrow.down.to.line",
            accessibilityLabel: "Insert value"
        )
        lookupButton.target = self
        lookupButton.action = #selector(submitLookupFromButton)

        lookupSurface.addSubview(lookupField)
        lookupSurface.addSubview(lookupButton)
        root.addSubview(lookupSurface)

        libraryRevealButton.target = self
        libraryRevealButton.action = #selector(showLibrary)
        libraryRevealButton.setAccessibilityLabel("Show current Insert key and value library")
        libraryRevealButton.setAccessibilityHelp("Opens a searchable read-only list of Dynamic and Custom insertions.")
        root.addSubview(libraryRevealButton)
    }

    private func configureCreate() {
        ShortcutUIStyle.configureContentSurface(keySurface, cornerRadius: 13)
        ShortcutUIStyle.configureContentSurface(valueSurface, cornerRadius: 13)
        configureTextField(
            keyField,
            placeholder: "Key · e.g. email",
            accessibilityLabel: "New insertion key"
        )
        configureTextField(
            valueField,
            placeholder: "Value · e.g. name@example.com",
            accessibilityLabel: "New insertion value"
        )
        keyField.delegate = self
        valueField.delegate = self

        arrowImageView.image = NSImage(
            systemSymbolName: "arrow.right",
            accessibilityDescription: "Maps key to value"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        arrowImageView.contentTintColor = ShortcutUIStyle.secondaryTextColor.withAlphaComponent(0.6)
        arrowImageView.imageScaling = .scaleProportionallyDown
        arrowImageView.setAccessibilityLabel("Maps key to value")

        configurePillButton(saveButton, title: "Save")
        saveButton.target = self
        saveButton.action = #selector(saveNewEntryFromButton)

        keySurface.addSubview(keyField)
        valueSurface.addSubview(valueField)
        createSurface.addSubview(keySurface)
        createSurface.addSubview(arrowImageView)
        createSurface.addSubview(valueSurface)
        createSurface.addSubview(saveButton)
        root.addSubview(createSurface)
    }

    private func configureManagement() {
        searchField.cell = InsetSearchFieldCell(textCell: "")
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.font = .systemFont(ofSize: 13.5)
        searchField.textColor = ShortcutUIStyle.primaryTextColor
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search keys or values",
            attributes: [
                .foregroundColor: ShortcutUIStyle.placeholderTextColor,
                .font: NSFont.systemFont(ofSize: 13.5),
            ]
        )
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = 17
        searchField.layer?.backgroundColor = ShortcutUIStyle.raisedSurfaceColor.cgColor
        searchField.layer?.borderWidth = 1
        searchField.layer?.borderColor = ShortcutUIStyle.contentBorderColor.cgColor
        searchField.setAccessibilityLabel("Search Insert entries")

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = rowsView
        root.addSubview(searchField)
        root.addSubview(scrollView)
    }

    private func setMode(_ mode: InsertPanelMode, animated: Bool) {
        let previousMode = self.mode
        let outgoing = modeViews(for: previousMode)
        let incoming = modeViews(for: mode)
        self.mode = mode
        statusLabel.stringValue = ""
        let management = mode == .browse || mode == .modify || mode == .delete
        let targetHeight: CGFloat = management ? 356 : (mode == .create ? 148 : 126)

        switch mode {
        case .lookup:
            titleLabel.stringValue = "Insert"
            contextLabel.stringValue = "/new · /modify · /delete"
            lookupField.stringValue = ""
            updateLookupButton()
            panel.makeFirstResponder(lookupField)
        case .browse:
            titleLabel.stringValue = "Insertions"
            contextLabel.stringValue = "Dynamic and custom values"
            searchField.stringValue = ""
            rebuildRows()
            panel.makeFirstResponder(searchField)
        case .create:
            titleLabel.stringValue = "New insertion"
            contextLabel.stringValue = "Key to value"
            keyField.stringValue = ""
            valueField.stringValue = ""
            updateSaveButton()
            panel.makeFirstResponder(keyField)
        case .modify:
            titleLabel.stringValue = "Modify insertions"
            contextLabel.stringValue = "Edit a field, then save"
            searchField.stringValue = ""
            rebuildRows()
            panel.makeFirstResponder(searchField)
        case .delete:
            titleLabel.stringValue = "Delete insertions"
            contextLabel.stringValue = "Choose an entry to remove"
            searchField.stringValue = ""
            rebuildRows()
            panel.makeFirstResponder(searchField)
        }

        var targetFrame = panel.frame
        targetFrame.origin.y += targetFrame.height - targetHeight
        targetFrame.size.height = targetHeight

        let targetTitleX: CGFloat = mode == .lookup ? 20 : 46
        let targetTitleWidth: CGFloat = mode == .lookup ? 250 : 224
        let targetTitleFrame = NSRect(x: targetTitleX, y: 16, width: targetTitleWidth, height: 20)

        layoutCurrentMode(height: targetHeight)

        if animated && panel.isVisible {
            incoming.forEach {
                $0.isHidden = false
                $0.alphaValue = 0
            }
            backButton.isHidden = false

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true

                panel.animator().setFrame(targetFrame, display: true)
                titleLabel.animator().frame = targetTitleFrame
                backButton.animator().alphaValue = mode == .lookup ? 0 : 1

                outgoing.filter { view in !incoming.contains { $0 === view } }.forEach {
                    $0.animator().alphaValue = 0
                }
                incoming.forEach {
                    $0.animator().alphaValue = 1
                }
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    outgoing.filter { view in !incoming.contains { $0 === view } }.forEach {
                        $0.isHidden = true
                        $0.alphaValue = 1
                    }
                    self.backButton.isHidden = (self.mode == .lookup)
                    self.backButton.alphaValue = (self.mode == .lookup) ? 0 : 1
                    self.layoutCurrentMode()
                }
            }
        } else {
            panel.setFrame(targetFrame, display: true)
            titleLabel.frame = targetTitleFrame
            backButton.isHidden = mode == .lookup
            backButton.alphaValue = mode == .lookup ? 0 : 1

            let allViews = [
                lookupSurface,
                libraryRevealButton,
                createSurface,
                searchField,
                scrollView,
            ]
            allViews.forEach { view in
                view.isHidden = !incoming.contains { $0 === view }
                view.alphaValue = 1
            }
            layoutCurrentMode()
        }
    }

    private func layoutCurrentMode(height overrideHeight: CGFloat? = nil) {
        let width = panel.frame.width
        let height = overrideHeight ?? panel.frame.height

        backButton.frame = NSRect(x: 10, y: 12, width: 30, height: 30)
        let titleX: CGFloat = mode == .lookup ? 20 : 46
        let titleWidth: CGFloat = mode == .lookup ? 250 : 224
        titleLabel.frame = NSRect(x: titleX, y: 16, width: titleWidth, height: 20)
        contextLabel.frame = NSRect(x: 270, y: 18, width: width - 286, height: 18)

        switch mode {
        case .lookup:
            let isError = !statusLabel.stringValue.isEmpty
            lookupSurface.frame = NSRect(x: 14, y: 46, width: width - 28, height: 60)
            lookupField.frame = NSRect(x: 16, y: 0, width: width - 110, height: 60)
            lookupButton.frame = NSRect(x: width - 68, y: 11, width: 38, height: 38)
            libraryRevealButton.frame = NSRect(
                x: width / 2 - 30,
                y: isError ? 134 : 112,
                width: 60,
                height: 10
            )
            statusLabel.frame = NSRect(x: 20, y: 118, width: width - 40, height: 16)
        case .create:
            createSurface.frame = NSRect(x: 14, y: 46, width: width - 28, height: 66)
            keySurface.frame = NSRect(x: 0, y: 11, width: 177, height: 44)
            keyField.frame = NSRect(x: 14, y: 0, width: 149, height: 44)
            arrowImageView.frame = NSRect(x: 182, y: 22, width: 24, height: 22)
            valueSurface.frame = NSRect(x: 212, y: 11, width: 247, height: 44)
            valueField.frame = NSRect(x: 14, y: 0, width: 219, height: 44)
            saveButton.frame = NSRect(x: 470, y: 15, width: 74, height: 36)
            statusLabel.frame = NSRect(x: 20, y: 122, width: width - 40, height: 16)
        case .browse, .modify, .delete:
            searchField.frame = NSRect(x: 16, y: 46, width: width - 32, height: 34)
            scrollView.frame = NSRect(x: 16, y: 90, width: width - 32, height: max(60, height - 120))
            statusLabel.frame = NSRect(x: 20, y: height - 24, width: width - 40, height: 16)
        }
    }

    private func rebuildRows() {
        rowsView.subviews.forEach { $0.removeFromSuperview() }
        let visibleEntries = InsertEntryMatcher.filtered(
            by: searchField.stringValue,
            entries: entries
        )
        let rowHeight: CGFloat = 50
        let itemHeight: CGFloat = 42
        let width = max(scrollView.contentSize.width, panel.frame.width - 32)
        if visibleEntries.isEmpty {
            let empty = NSTextField(labelWithString: entries.isEmpty
                ? "No saved insertions yet. Use /new to add one."
                : "No matching entries.")
            empty.font = .systemFont(ofSize: 13, weight: .medium)
            empty.textColor = ShortcutUIStyle.secondaryTextColor
            empty.alignment = .center
            empty.frame = NSRect(x: 10, y: 46, width: width - 20, height: 20)
            rowsView.addSubview(empty)
            rowsView.frame = NSRect(x: 0, y: 0, width: width, height: 120)
            return
        }

        for (index, entry) in visibleEntries.enumerated() {
            let row = InsertEntryRowView(
                frame: NSRect(x: 0, y: CGFloat(index) * rowHeight, width: width, height: itemHeight),
                entry: entry,
                isDeleting: mode == .delete,
                isBrowsing: mode == .browse,
                onSave: { [weak self] id, key, value in
                    self?.updateEntry(id: id, key: key, value: value)
                },
                onDelete: { [weak self] id in
                    self?.deleteEntry(id: id)
                }
            )
            rowsView.addSubview(row)
        }
        rowsView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: CGFloat(visibleEntries.count) * rowHeight
        )
    }

    private func submitLookup() {
        guard !isResolving else {
            return
        }
        let query = lookupField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return
        }
        if query.hasPrefix("/") {
            showLookupError("Commands: /new, /modify, or /delete")
            return
        }
        onLookup?(query)
    }

    private func saveNewEntry() {
        guard saveButton.isEnabled, let onCreate else {
            return
        }
        do {
            entries = try onCreate(keyField.stringValue, valueField.stringValue)
            statusLabel.textColor = ShortcutUIStyle.successAccentColor
            statusLabel.stringValue = "Saved · add another or go back to insert"
            keyField.stringValue = ""
            valueField.stringValue = ""
            updateSaveButton()
            panel.makeFirstResponder(keyField)
        } catch {
            statusLabel.textColor = ShortcutUIStyle.warningAccentColor
            statusLabel.stringValue = error.localizedDescription
        }
    }

    private func updateEntry(id: UUID, key: String, value: String) {
        guard let onUpdate else {
            return
        }
        do {
            entries = try onUpdate(id, key, value)
            statusLabel.textColor = ShortcutUIStyle.successAccentColor
            statusLabel.stringValue = "Insertion updated"
            rebuildRows()
        } catch {
            statusLabel.textColor = ShortcutUIStyle.warningAccentColor
            statusLabel.stringValue = error.localizedDescription
        }
    }

    private func deleteEntry(id: UUID) {
        guard let onDelete else {
            return
        }
        do {
            entries = try onDelete(id)
            statusLabel.textColor = ShortcutUIStyle.successAccentColor
            statusLabel.stringValue = "Insertion deleted"
            rebuildRows()
        } catch {
            statusLabel.textColor = ShortcutUIStyle.warningAccentColor
            statusLabel.stringValue = error.localizedDescription
        }
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: mouse.x - 290, y: mouse.y - 70, width: 580, height: 126)
        let targetX = visible.midX - panel.frame.width / 2
        let targetY = visible.midY - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: targetX, y: targetY))
    }



    private func configureTextField(
        _ field: NSTextField,
        placeholder: String,
        accessibilityLabel: String
    ) {
        field.cell = VerticallyCenteredTextFieldCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14.5)
        field.textColor = ShortcutUIStyle.primaryTextColor
        field.placeholderString = placeholder
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel(accessibilityLabel)
    }

    private func configureCircleButton(
        _ button: NSButton,
        symbol: String,
        accessibilityLabel: String
    ) {
        button.isBordered = false
        button.focusRingType = .none
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        button.contentTintColor = ShortcutUIStyle.shellColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 20
        button.layer?.backgroundColor = ShortcutUIStyle.primaryTextColor.cgColor
        button.setAccessibilityLabel(accessibilityLabel)
    }

    private func configurePillButton(_ button: NSButton, title: String) {
        button.title = title
        button.isBordered = false
        button.focusRingType = .none
        button.font = .systemFont(ofSize: 12.5, weight: .semibold)
        button.contentTintColor = ShortcutUIStyle.primaryTextColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 12
        button.layer?.backgroundColor = ShortcutUIStyle.accentColor.withAlphaComponent(0.78).cgColor
    }

    private func updateLookupButton() {
        let enabled = !lookupField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        lookupButton.isEnabled = enabled
        lookupButton.alphaValue = enabled ? 1 : 0.34
    }

    private func clearLookupStatus() {
        guard mode == .lookup, !statusLabel.stringValue.isEmpty else {
            return
        }
        var targetFrame = panel.frame
        targetFrame.origin.y += targetFrame.height - 126
        targetFrame.size.height = 126

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
            statusLabel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.mode == .lookup else { return }
                self.statusLabel.stringValue = ""
                self.statusLabel.alphaValue = 1
                self.layoutCurrentMode(height: 126)
            }
        }
    }

    private func setFieldSurface(_ surface: NSView, focused: Bool) {
        surface.layer?.borderWidth = focused ? 1.5 : 1
        surface.layer?.borderColor = focused
            ? ShortcutUIStyle.focusBorderColor.cgColor
            : ShortcutUIStyle.contentBorderColor.cgColor
    }

    private func setSearchFieldFocused(_ focused: Bool) {
        searchField.layer?.borderWidth = focused ? 1.5 : 1
        searchField.layer?.borderColor = focused
            ? ShortcutUIStyle.focusBorderColor.cgColor
            : ShortcutUIStyle.contentBorderColor.cgColor
    }

    private func modeViews(for mode: InsertPanelMode) -> [NSView] {
        switch mode {
        case .lookup:
            [lookupSurface, libraryRevealButton]
        case .browse:
            [searchField, scrollView]
        case .create:
            [createSurface]
        case .modify, .delete:
            [searchField, scrollView]
        }
    }

    private func updateSaveButton() {
        let hasKey = !keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasValue = !valueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        saveButton.isEnabled = hasKey && hasValue
        saveButton.alphaValue = saveButton.isEnabled ? 1 : 0.34
    }

    @objc private func submitLookupFromButton() {
        submitLookup()
    }

    @objc private func saveNewEntryFromButton() {
        saveNewEntry()
    }

    @objc private func backToLookup() {
        setMode(.lookup, animated: true)
    }

    @objc private func showLibrary() {
        setMode(.browse, animated: true)
    }
}

@MainActor
private final class InsertEntryRowView: NSView, NSTextFieldDelegate {
    private let id: UUID
    private let keySurface = NSView()
    private let valueSurface = NSView()
    private let keyField = NSTextField()
    private let arrowImageView = NSImageView()
    private let valueField = NSTextField()
    private let actionButton = InsertActionButton()
    private let onSave: (UUID, String, String) -> Void
    private let onDelete: (UUID) -> Void
    private let isDeleting: Bool
    private let isBrowsing: Bool
    private let isBuiltIn: Bool
    private let originalKey: String
    private let originalValue: String
    private var isCopiedFeedback = false
    private var copyFeedbackResetWorkItem: DispatchWorkItem?

    init(
        frame: NSRect,
        entry: InsertEntry,
        isDeleting: Bool,
        isBrowsing: Bool,
        onSave: @escaping (UUID, String, String) -> Void,
        onDelete: @escaping (UUID) -> Void
    ) {
        id = entry.id
        self.isDeleting = isDeleting
        self.isBrowsing = isBrowsing
        isBuiltIn = entry.builtIn
        originalKey = entry.key
        originalValue = entry.value
        self.onSave = onSave
        self.onDelete = onDelete
        super.init(frame: frame)

        ShortcutUIStyle.configureContentSurface(keySurface, cornerRadius: 10)
        ShortcutUIStyle.configureContentSurface(valueSurface, cornerRadius: 10)

        configureField(keyField, value: entry.key)
        configureField(valueField, value: entry.value)
        keyField.font = .systemFont(ofSize: 13, weight: .semibold)
        valueField.font = .systemFont(ofSize: 13)
        keyField.isEditable = !isDeleting && !isBuiltIn
        valueField.isEditable = !isDeleting && !isBuiltIn
        keyField.delegate = self
        valueField.delegate = self
        keyField.textColor = ShortcutUIStyle.primaryTextColor
        valueField.textColor = isBuiltIn ? ShortcutUIStyle.secondaryTextColor : ShortcutUIStyle.primaryTextColor

        arrowImageView.image = NSImage(
            systemSymbolName: "arrow.right",
            accessibilityDescription: "Maps key to value"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        arrowImageView.contentTintColor = ShortcutUIStyle.secondaryTextColor.withAlphaComponent(0.6)
        arrowImageView.imageScaling = .scaleProportionallyDown
        arrowImageView.setAccessibilityLabel("Maps key to value")

        actionButton.isBordered = false
        actionButton.focusRingType = .none
        actionButton.font = .systemFont(ofSize: 11.5, weight: .semibold)
        actionButton.imagePosition = .imageLeading
        actionButton.imageScaling = .scaleProportionallyDown
        if isBuiltIn {
            actionButton.target = nil
            actionButton.action = nil
        } else {
            actionButton.target = self
            actionButton.action = #selector(performAction)
        }
        actionButton.wantsLayer = true
        actionButton.layer?.cornerRadius = 9
        refreshActionAppearance()

        keySurface.addSubview(keyField)
        valueSurface.addSubview(valueField)
        addSubview(keySurface)
        addSubview(arrowImageView)
        addSubview(valueSurface)
        addSubview(actionButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let actionWidth = fittedActionWidth
        let keyWidth: CGFloat = 154
        let arrowX: CGFloat = 162
        let arrowWidth: CGFloat = 18
        let valueX: CGFloat = 188
        let actionX = bounds.width - actionWidth
        let valueWidth = max(80, actionX - valueX - 8)
        let itemHeight = bounds.height

        keySurface.frame = NSRect(x: 0, y: 0, width: keyWidth, height: itemHeight)
        keyField.frame = NSRect(x: 10, y: 0, width: keyWidth - 20, height: itemHeight)
        arrowImageView.frame = NSRect(x: arrowX, y: floor((itemHeight - 18) / 2), width: arrowWidth, height: 18)
        valueSurface.frame = NSRect(x: valueX, y: 0, width: valueWidth, height: itemHeight)
        valueField.frame = NSRect(x: 10, y: 0, width: valueWidth - 20, height: itemHeight)
        actionButton.frame = NSRect(x: actionX, y: floor((itemHeight - 32) / 2), width: actionWidth, height: 32)
    }

    private var hasChanges: Bool {
        keyField.stringValue != originalKey || valueField.stringValue != originalValue
    }

    private var fittedActionWidth: CGFloat {
        let titleWidth = ceil((actionButton.title as NSString).size(
            withAttributes: [.font: actionButton.font ?? NSFont.systemFont(ofSize: 11.5, weight: .semibold)]
        ).width)
        let imageWidth: CGFloat = actionButton.image == nil ? 0 : 16
        return max(68, titleWidth + imageWidth + 22)
    }

    private func refreshActionAppearance() {
        let title: String
        let symbol: String
        let tint: NSColor
        let background: NSColor
        let hoveredBackground: NSColor
        let border: NSColor
        let isEnabled: Bool

        if isCopiedFeedback {
            title = "Copied"
            symbol = "checkmark"
            tint = ShortcutUIStyle.successAccentColor
            background = ShortcutUIStyle.successAccentColor.withAlphaComponent(0.15)
            hoveredBackground = ShortcutUIStyle.successAccentColor.withAlphaComponent(0.22)
            border = ShortcutUIStyle.successAccentColor.withAlphaComponent(0.38)
            isEnabled = true
        } else if isBuiltIn {
            title = "Dynamic"
            symbol = "clock.arrow.circlepath"
            tint = ShortcutUIStyle.accentColor
            background = ShortcutUIStyle.accentColor.withAlphaComponent(0.12)
            hoveredBackground = ShortcutUIStyle.accentColor.withAlphaComponent(0.12)
            border = ShortcutUIStyle.accentColor.withAlphaComponent(0.24)
            isEnabled = false
        } else if isDeleting {
            title = "Delete"
            symbol = "trash"
            tint = ShortcutUIStyle.warningAccentColor
            background = ShortcutUIStyle.warningAccentColor.withAlphaComponent(0.12)
            hoveredBackground = ShortcutUIStyle.warningAccentColor.withAlphaComponent(0.22)
            border = ShortcutUIStyle.warningAccentColor.withAlphaComponent(0.30)
            isEnabled = true
        } else if hasChanges {
            title = "Save"
            symbol = "checkmark.circle"
            tint = ShortcutUIStyle.primaryTextColor
            background = ShortcutUIStyle.accentColor.withAlphaComponent(0.85)
            hoveredBackground = ShortcutUIStyle.accentColor
            border = ShortcutUIStyle.accentColor
            let validEdit = !keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !valueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            isEnabled = validEdit
        } else if isBrowsing {
            title = "Copy"
            symbol = "doc.on.doc"
            tint = ShortcutUIStyle.secondaryTextColor
            background = ShortcutUIStyle.raisedSurfaceColor
            hoveredBackground = ShortcutUIStyle.raisedSurfaceColor.blended(withFraction: 0.15, of: .white) ?? ShortcutUIStyle.raisedSurfaceColor
            border = ShortcutUIStyle.contentBorderColor
            isEnabled = true
        } else {
            title = "Save"
            symbol = "checkmark.circle"
            tint = ShortcutUIStyle.secondaryTextColor
            background = ShortcutUIStyle.accentColor.withAlphaComponent(0.15)
            hoveredBackground = ShortcutUIStyle.accentColor.withAlphaComponent(0.22)
            border = ShortcutUIStyle.accentColor.withAlphaComponent(0.25)
            isEnabled = false
        }

        actionButton.title = title
        actionButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        )
        actionButton.contentTintColor = tint
        actionButton.setBackgroundColors(normal: background, hovered: hoveredBackground)
        actionButton.layer?.borderWidth = 1
        actionButton.layer?.borderColor = border.cgColor
        actionButton.setAccessibilityLabel("\(title) insertion")
        actionButton.isEnabled = isEnabled
        actionButton.alphaValue = isEnabled || isBuiltIn ? 1 : 0.40
        needsLayout = true
    }

    private func configureField(_ field: NSTextField, value: String) {
        field.cell = VerticallyCenteredTextFieldCell(textCell: "")
        field.stringValue = value
        field.isSelectable = true
        field.isEnabled = true
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        setFocused(field === keyField ? keySurface : valueSurface, focused: true)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isBuiltIn else { return }
        refreshActionAppearance()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        setFocused(field === keyField ? keySurface : valueSurface, focused: false)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)), !isBuiltIn else {
            return false
        }
        if control === keyField {
            window?.makeFirstResponder(valueField)
        } else {
            performAction()
        }
        return true
    }

    private func setFocused(_ surface: NSView, focused: Bool) {
        surface.layer?.borderWidth = focused ? 1.5 : 1
        surface.layer?.borderColor = focused
            ? ShortcutUIStyle.focusBorderColor.cgColor
            : ShortcutUIStyle.contentBorderColor.cgColor
    }

    @objc private func performAction() {
        if isDeleting {
            onDelete(id)
        } else if hasChanges {
            let k = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let v = valueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty, !v.isEmpty else { return }
            onSave(id, k, v)
        } else if isBrowsing {
            copyValue()
        }
    }

    private func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(valueField.stringValue, forType: .string)
        copyFeedbackResetWorkItem?.cancel()
        isCopiedFeedback = true
        refreshActionAppearance()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isCopiedFeedback = false
            self.refreshActionAppearance()
        }
        copyFeedbackResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }
}

private final class InsetSearchFieldCell: NSSearchFieldCell {
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let leftInset: CGFloat = 36
        let rightInset: CGFloat = 28
        let font = self.font ?? .systemFont(ofSize: 13.5)
        let naturalHeight: CGFloat = ceil(font.ascender - font.descender + font.leading + 2)
        let y = floor((rect.height - naturalHeight) / 2)
        return NSRect(
            x: leftInset,
            y: y,
            width: max(0, rect.width - leftInset - rightInset),
            height: naturalHeight
        )
    }

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        var r = super.searchButtonRect(forBounds: rect)
        r.origin.x = 12
        r.origin.y = floor((rect.height - r.height) / 2)
        return r
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        var r = super.cancelButtonRect(forBounds: rect)
        r.origin.x = rect.width - r.width - 10
        r.origin.y = floor((rect.height - r.height) / 2)
        return r
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        searchTextRect(forBounds: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: searchTextRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: searchTextRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private func centeredRect(for frame: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: frame)
        let naturalHeight: CGFloat
        if let font {
            naturalHeight = ceil(font.ascender - font.descender + font.leading + 2)
        } else {
            naturalHeight = min(22, rect.height)
        }
        if naturalHeight < rect.height {
            rect.origin.y += floor((rect.height - naturalHeight) / 2) - 1
            rect.size.height = naturalHeight
        }
        return rect
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(for: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: centeredRect(for: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: centeredRect(for: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

private final class InsertActionButton: NSButton {
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
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect,
        ]
        let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self)
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
        if isEnabled && target != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

private final class ThinLibraryButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        focusRingType = .none
        imagePosition = .noImage
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect,
        ]
        let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(
            x: bounds.midX - 22,
            y: bounds.midY - 1,
            width: 44,
            height: 2
        )
        let color: NSColor
        if isHighlighted {
            color = ShortcutUIStyle.accentColor.withAlphaComponent(0.9)
        } else if isHovered {
            color = ShortcutUIStyle.secondaryTextColor.withAlphaComponent(0.85)
        } else {
            color = ShortcutUIStyle.secondaryTextColor.withAlphaComponent(0.45)
        }
        color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 1, yRadius: 1).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class InsertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) {
                    return true
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
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
