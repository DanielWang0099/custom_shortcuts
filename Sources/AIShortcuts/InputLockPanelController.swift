import AppKit

@MainActor
final class InputLockPanelController: NSObject, NSWindowDelegate {
    private let panel: InputLockChoicePanel
    private var cards: [NSView] = []
    private var selectedIndex = 0
    private var selectionHandler: ((InputLockMode) -> Void)?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = InputLockChoicePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 176),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.owner = self
        panel.delegate = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = InputLockSurfaceView(frame: panel.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: "Input Lock")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = ShortcutUIStyle.primaryTextColor
        title.frame = NSRect(x: 22, y: 141, width: 150, height: 22)
        background.addSubview(title)

        let hint = NSTextField(labelWithString: "↑↓ choose  ·  Return confirm  ·  Esc close")
        hint.font = .systemFont(ofSize: 11.5, weight: .medium)
        hint.textColor = ShortcutUIStyle.secondaryTextColor
        hint.alignment = .right
        hint.frame = NSRect(x: 150, y: 143, width: 228, height: 18)
        background.addSubview(hint)

        addChoice(
            index: 0,
            title: "Keyboard Lock",
            subtitle: "Blocks every keystroke except ⌃⌥⌘L",
            frame: NSRect(x: 18, y: 78, width: 364, height: 52),
            to: background
        )
        addChoice(
            index: 1,
            title: "Shortcut Lock",
            subtitle: "Blocks modifier shortcuts; normal typing stays active",
            frame: NSRect(x: 18, y: 16, width: 364, height: 52),
            to: background
        )
        panel.contentView = background
        updateSelection()
    }

    func show(onSelect: @escaping (InputLockMode) -> Void) {
        selectionHandler = onSelect
        selectedIndex = 0
        updateSelection()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: mouse.x - 200, y: mouse.y - 88, width: 400, height: 176)
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.midY - panel.frame.height / 2
        ))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    func moveSelection(_ delta: Int) {
        selectedIndex = min(max(0, selectedIndex + delta), cards.count - 1)
        updateSelection()
    }

    func confirmSelection() {
        let mode: InputLockMode = selectedIndex == 0 ? .keyboard : .shortcuts
        dismiss()
        selectionHandler?(mode)
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    private func addChoice(
        index: Int,
        title: String,
        subtitle: String,
        frame: NSRect,
        to background: NSView
    ) {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 12

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14.5, weight: .semibold)
        titleLabel.textColor = ShortcutUIStyle.primaryTextColor
        titleLabel.frame = NSRect(x: 16, y: 25, width: 320, height: 18)
        card.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.textColor = ShortcutUIStyle.secondaryTextColor
        subtitleLabel.frame = NSRect(x: 16, y: 8, width: 330, height: 16)
        card.addSubview(subtitleLabel)

        let button = NSButton(frame: card.bounds)
        button.isBordered = false
        button.title = ""
        button.tag = index
        button.target = self
        button.action = #selector(selectChoice(_:))
        button.setAccessibilityLabel("\(title). \(subtitle)")
        card.addSubview(button)

        cards.append(card)
        background.addSubview(card)
    }

    @objc private func selectChoice(_ sender: NSButton) {
        selectedIndex = sender.tag
        updateSelection()
        confirmSelection()
    }

    private func updateSelection() {
        for (index, card) in cards.enumerated() {
            let selected = index == selectedIndex
            card.layer?.backgroundColor = selected
                ? ShortcutUIStyle.accentColor.withAlphaComponent(0.14).cgColor
                : ShortcutUIStyle.raisedSurfaceColor.cgColor
            card.layer?.borderWidth = selected ? 1.5 : 1
            card.layer?.borderColor = selected
                ? ShortcutUIStyle.focusBorderColor.cgColor
                : ShortcutUIStyle.contentBorderColor.cgColor
        }
    }
}

@MainActor
final class InputLockIndicatorController {
    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = InputLockSurfaceView(frame: panel.contentView?.bounds ?? .zero)
        let icon = NSImageView(frame: NSRect(x: 16, y: 14, width: 24, height: 24))
        icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")
        icon.contentTintColor = ShortcutUIStyle.warningAccentColor
        background.addSubview(icon)

        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.textColor = ShortcutUIStyle.primaryTextColor
        title.frame = NSRect(x: 50, y: 25, width: 280, height: 18)
        background.addSubview(title)

        let hint = NSTextField(labelWithString: "Press ⌃⌥⌘L to restore input")
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = ShortcutUIStyle.secondaryTextColor
        hint.frame = NSRect(x: 50, y: 9, width: 280, height: 16)
        background.addSubview(hint)
        panel.contentView = background
    }

    func show(mode: InputLockMode) {
        title.stringValue = mode.title
        let visible = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.maxY - panel.frame.height - 18
        ))
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}

private final class InputLockChoicePanel: NSPanel {
    weak var owner: InputLockPanelController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            owner?.moveSelection(1)
        case 126:
            owner?.moveSelection(-1)
        case 36, 76:
            owner?.confirmSelection()
        case 53:
            owner?.dismiss()
        default:
            super.keyDown(with: event)
        }
    }
}

private final class InputLockSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ShortcutUIStyle.configurePanelSurface(
            self,
            cornerRadius: ShortcutUIStyle.promptCornerRadius
        )
    }

    required init?(coder: NSCoder) {
        nil
    }
}
