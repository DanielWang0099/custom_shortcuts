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
    private let root = NSView()
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
    private let arrowLabel = NSTextField(labelWithString: "→")
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
        let previousFrame = lookupSurface.frame
        statusLabel.textColor = ShortcutUIStyle.warningAccentColor
        statusLabel.stringValue = message
        statusLabel.alphaValue = 0
        resizePanel(to: 150, animated: true)
        let targetFrame = lookupSurface.frame
        lookupSurface.frame = previousFrame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            lookupSurface.animator().frame = targetFrame
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

        arrowLabel.font = .systemFont(ofSize: 16, weight: .medium)
        arrowLabel.textColor = ShortcutUIStyle.accentColor
        arrowLabel.alignment = .center

        configurePillButton(saveButton, title: "Save")
        saveButton.target = self
        saveButton.action = #selector(saveNewEntryFromButton)

        keySurface.addSubview(keyField)
        valueSurface.addSubview(valueField)
        createSurface.addSubview(keySurface)
        createSurface.addSubview(arrowLabel)
        createSurface.addSubview(valueSurface)
        createSurface.addSubview(saveButton)
        root.addSubview(createSurface)
    }

    private func configureManagement() {
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13.5)
        searchField.textColor = ShortcutUIStyle.primaryTextColor
        searchField.backgroundColor = ShortcutUIStyle.raisedSurfaceColor
        searchField.placeholderString = "Search keys or values"
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
        let height: CGFloat = management ? 330 : (mode == .create ? 148 : 126)

        if animated, panel.isVisible {
            incoming.forEach {
                $0.isHidden = false
                $0.alphaValue = 0
            }
            titleLabel.alphaValue = 0.45
            contextLabel.alphaValue = 0.35
            backButton.isHidden = false
            backButton.alphaValue = mode == .lookup ? 1 : 0
        }
        resizePanel(to: height, animated: animated)

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
            contextLabel.stringValue = "key  →  value"
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
        layoutCurrentMode()
        applyModeVisibility(
            outgoing: outgoing,
            incoming: incoming,
            animated: animated
        )
    }

    private func layoutCurrentMode() {
        let width = panel.frame.width
        let height = panel.frame.height
        titleLabel.frame = NSRect(x: 20, y: height - 39, width: 250, height: 20)
        backButton.frame = NSRect(x: 14, y: height - 42, width: 24, height: 24)
        if !backButton.isHidden {
            titleLabel.frame.origin.x = 42
            titleLabel.frame.size.width = 228
        }
        contextLabel.frame = NSRect(x: 270, y: height - 38, width: width - 290, height: 18)
        statusLabel.frame = NSRect(x: 20, y: 12, width: width - 40, height: 16)

        let lookupY: CGFloat = statusLabel.stringValue.isEmpty ? 18 : 38
        lookupSurface.frame = NSRect(x: 14, y: lookupY, width: width - 28, height: 62)
        lookupField.frame = NSRect(x: 18, y: 0, width: width - 112, height: 62)
        lookupButton.frame = NSRect(x: width - 72, y: 11, width: 40, height: 40)
        libraryRevealButton.frame = NSRect(
            x: width / 2 - 34,
            y: 0,
            width: 68,
            height: 18
        )

        createSurface.frame = NSRect(x: 14, y: 30, width: width - 28, height: 66)
        keySurface.frame = NSRect(x: 0, y: 11, width: 177, height: 44)
        keyField.frame = NSRect(x: 14, y: 0, width: 149, height: 44)
        arrowLabel.frame = NSRect(x: 182, y: 22, width: 24, height: 22)
        valueSurface.frame = NSRect(x: 212, y: 11, width: 247, height: 44)
        valueField.frame = NSRect(x: 14, y: 0, width: 219, height: 44)
        saveButton.frame = NSRect(x: 470, y: 15, width: 74, height: 36)

        searchField.frame = NSRect(x: 18, y: height - 88, width: width - 36, height: 34)
        scrollView.frame = NSRect(x: 14, y: 18, width: width - 28, height: height - 116)
    }

    private func rebuildRows() {
        rowsView.subviews.forEach { $0.removeFromSuperview() }
        let visibleEntries = InsertEntryMatcher.filtered(
            by: searchField.stringValue,
            entries: entries
        )
        let rowHeight: CGFloat = 54
        let width = max(scrollView.contentSize.width, panel.frame.width - 46)
        if visibleEntries.isEmpty {
            let empty = NSTextField(labelWithString: entries.isEmpty
                ? "No saved insertions yet. Use /new to add one."
                : "No matching entries.")
            empty.font = .systemFont(ofSize: 13, weight: .medium)
            empty.textColor = ShortcutUIStyle.secondaryTextColor
            empty.alignment = .center
            empty.frame = NSRect(x: 10, y: 42, width: width - 20, height: 20)
            rowsView.addSubview(empty)
            rowsView.frame = NSRect(x: 0, y: 0, width: width, height: 120)
            return
        }

        for (index, entry) in visibleEntries.enumerated() {
            let row = InsertEntryRowView(
                frame: NSRect(x: 0, y: CGFloat(index) * rowHeight, width: width, height: 48),
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

    private func resizePanel(to height: CGFloat, animated: Bool) {
        guard panel.frame.height != height else {
            layoutCurrentMode()
            return
        }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        if animated, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.layoutCurrentMode()
                }
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        root.frame = NSRect(origin: .zero, size: frame.size)
        layoutCurrentMode()
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
        let previousFrame = lookupSurface.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            statusLabel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.mode == .lookup else {
                    self.statusLabel.stringValue = ""
                    self.statusLabel.alphaValue = 1
                    return
                }
                self.statusLabel.stringValue = ""
                self.resizePanel(to: 126, animated: true)
                let targetFrame = self.lookupSurface.frame
                self.lookupSurface.frame = previousFrame
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.lookupSurface.animator().frame = targetFrame
                }
                self.statusLabel.alphaValue = 1
            }
        }
    }

    private func setFieldSurface(_ surface: NSView, focused: Bool) {
        surface.layer?.borderWidth = focused ? 1.5 : 1
        surface.layer?.borderColor = focused
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

    private func applyModeVisibility(
        outgoing: [NSView],
        incoming: [NSView],
        animated: Bool
    ) {
        let allViews = [
            lookupSurface,
            libraryRevealButton,
            createSurface,
            searchField,
            scrollView,
        ]
        let isIncoming: (NSView) -> Bool = { view in
            incoming.contains { $0 === view }
        }
        guard animated, panel.isVisible else {
            allViews.forEach {
                $0.isHidden = !isIncoming($0)
                $0.alphaValue = 1
            }
            backButton.isHidden = mode == .lookup
            backButton.alphaValue = 1
            titleLabel.alphaValue = 1
            contextLabel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            outgoing.filter { view in !isIncoming(view) }.forEach {
                $0.animator().alphaValue = 0
            }
            incoming.forEach { $0.animator().alphaValue = 1 }
            titleLabel.animator().alphaValue = 1
            contextLabel.animator().alphaValue = 1
            backButton.animator().alphaValue = mode == .lookup ? 0 : 1
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let currentIncoming = self.modeViews(for: self.mode)
                let currentViews = [
                    self.lookupSurface,
                    self.libraryRevealButton,
                    self.createSurface,
                    self.searchField,
                    self.scrollView,
                ]
                currentViews.forEach { view in
                    view.isHidden = !currentIncoming.contains { $0 === view }
                    view.alphaValue = 1
                }
                self.backButton.isHidden = self.mode == .lookup
                self.backButton.alphaValue = 1
            }
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
    private let arrowLabel = NSTextField(labelWithString: "→")
    private let valueField = NSTextField()
    private let actionButton = NSButton()
    private let onSave: (UUID, String, String) -> Void
    private let onDelete: (UUID) -> Void
    private let isDeleting: Bool
    private let isBrowsing: Bool
    private let isBuiltIn: Bool
    private let originalKey: String
    private let originalValue: String

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

        ShortcutUIStyle.configureContentSurface(keySurface, cornerRadius: 12)
        ShortcutUIStyle.configureContentSurface(valueSurface, cornerRadius: 12)

        configureField(keyField, value: entry.key, width: 158)
        configureField(valueField, value: entry.value, width: frame.width - 250)
        keyField.isEditable = !isDeleting && !isBuiltIn
        valueField.isEditable = !isDeleting && !isBuiltIn
        keyField.delegate = self
        valueField.delegate = self
        if isDeleting || isBuiltIn {
            keyField.textColor = ShortcutUIStyle.primaryTextColor
            valueField.textColor = ShortcutUIStyle.secondaryTextColor
        }

        arrowLabel.font = .systemFont(ofSize: 14, weight: .medium)
        arrowLabel.textColor = ShortcutUIStyle.accentColor
        arrowLabel.alignment = .center

        actionButton.isBordered = false
        actionButton.focusRingType = .none
        actionButton.font = .systemFont(ofSize: 12, weight: .semibold)
        if isBuiltIn {
            actionButton.image = NSImage(
                systemSymbolName: "clock.arrow.circlepath",
                accessibilityDescription: "Dynamic insertion"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
            )
            actionButton.imagePosition = .imageLeading
        } else {
            actionButton.target = self
            actionButton.action = #selector(performAction)
        }
        actionButton.wantsLayer = true
        actionButton.layer?.cornerRadius = 10
        refreshActionAppearance()

        keySurface.addSubview(keyField)
        valueSurface.addSubview(valueField)
        addSubview(keySurface)
        addSubview(arrowLabel)
        addSubview(valueSurface)
        addSubview(actionButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let actionWidth = fittedActionWidth
        let keyWidth: CGFloat = 168
        let valueX: CGFloat = 202
        let actionX = bounds.width - actionWidth
        keySurface.frame = NSRect(x: 0, y: 2, width: keyWidth, height: 44)
        keyField.frame = NSRect(x: 12, y: 0, width: keyWidth - 24, height: 44)
        arrowLabel.frame = NSRect(x: 174, y: 13, width: 22, height: 22)
        valueSurface.frame = NSRect(
            x: valueX,
            y: 2,
            width: max(100, actionX - valueX - 10),
            height: 44
        )
        valueField.frame = NSRect(
            x: 12,
            y: 0,
            width: max(76, valueSurface.bounds.width - 24),
            height: 44
        )
        actionButton.frame = NSRect(x: actionX, y: 7, width: actionWidth, height: 34)
    }

    private var hasChanges: Bool {
        keyField.stringValue != originalKey || valueField.stringValue != originalValue
    }

    private var fittedActionWidth: CGFloat {
        let titleWidth = ceil((actionButton.title as NSString).size(
            withAttributes: [.font: actionButton.font ?? NSFont.systemFont(ofSize: 12)]
        ).width)
        let imageWidth: CGFloat = actionButton.image == nil ? 0 : 17
        return min(98, max(64, titleWidth + imageWidth + 22))
    }

    private func refreshActionAppearance() {
        let title: String
        let tint: NSColor
        let background: NSColor

        if isBuiltIn {
            title = "Dynamic"
            tint = ShortcutUIStyle.accentColor
            background = ShortcutUIStyle.accentColor.withAlphaComponent(0.12)
        } else if isDeleting || (isBrowsing && !hasChanges) {
            title = "Delete"
            tint = ShortcutUIStyle.warningAccentColor
            background = ShortcutUIStyle.warningAccentColor.withAlphaComponent(0.12)
        } else if isBrowsing {
            title = "Modify"
            tint = ShortcutUIStyle.primaryTextColor
            background = ShortcutUIStyle.accentColor.withAlphaComponent(0.60)
        } else {
            title = "Save"
            tint = ShortcutUIStyle.primaryTextColor
            background = ShortcutUIStyle.accentColor.withAlphaComponent(0.60)
        }

        actionButton.title = title
        actionButton.contentTintColor = tint
        actionButton.layer?.backgroundColor = background.cgColor
        actionButton.setAccessibilityLabel("\(title) insertion")

        let validEdit = !keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !valueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        actionButton.isEnabled = !isBrowsing || !hasChanges || validEdit
        actionButton.alphaValue = actionButton.isEnabled ? 1 : 0.38
        needsLayout = true
    }

    private func configureField(_ field: NSTextField, value: String, width: CGFloat) {
        field.cell = VerticallyCenteredTextFieldCell(textCell: "")
        field.stringValue = value
        field.isSelectable = true
        field.isEnabled = true
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = ShortcutUIStyle.primaryTextColor
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.frame.size.width = width
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        setFocused(field === keyField ? keySurface : valueSurface, focused: true)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard isBrowsing, !isBuiltIn else { return }
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
        } else if !isBrowsing || hasChanges {
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
        if isDeleting || (isBrowsing && !hasChanges) {
            onDelete(id)
        } else {
            onSave(id, keyField.stringValue, valueField.stringValue)
        }
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

private final class ThinLibraryButton: NSButton {
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

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(
            x: bounds.midX - 23,
            y: bounds.midY - 1.5,
            width: 46,
            height: 3
        )
        let color = isHighlighted
            ? ShortcutUIStyle.accentColor.withAlphaComponent(0.82)
            : ShortcutUIStyle.secondaryTextColor.withAlphaComponent(0.56)
        color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 1.5, yRadius: 1.5).fill()
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
    override var canBecomeMain: Bool { false }
}
