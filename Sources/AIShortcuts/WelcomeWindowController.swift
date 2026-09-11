import AppKit
import AIShortcutsCore

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let panel: WelcomePanel
    private let root = NSView()

    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Welcome to AI Shortcuts")
    private let subtitleLabel = NSTextField(
        labelWithString: "Intelligent keyboard shortcuts powered by your own AI model."
    )
    private let closeButton = NSButton()

    private let cardView = NSView()

    private let menuBarIconView = NSImageView()
    private let menuBarTitleLabel = NSTextField(labelWithString: "Lives in your top menu bar")
    private let menuBarDescLabel = NSTextField(
        labelWithString: "The app has no regular window. Look for the icon in the upper status bar."
    )

    private let setupIconView = NSImageView()
    private let setupTitleLabel = NSTextField(labelWithString: "Quick setup & permissions")
    private let setupDescLabel = NSTextField(
        labelWithString: "Grant Accessibility when prompted, configure your API key in Model Settings, and you're ready!"
    )

    private let dontShowCheckbox = NSButton()
    private let settingsButton = WelcomeActionButton(title: "Configure Model Settings", target: nil, action: nil)
    private let gotItButton = WelcomeActionButton(title: "Got it", target: nil, action: nil)

    private let stateStore: AppStateStore
    var onOpenModelSettings: (() -> Void)?

    init(stateStore: AppStateStore) {
        self.stateStore = stateStore
        panel = WelcomePanel(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.owner = self
        configureWindow()
        configureContent()
    }

    func show() {
        dontShowCheckbox.state = stateStore.welcomeDismissed ? .on : .off
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel.orderOut(nil)
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
        panel.setAccessibilityLabel("Welcome to AI Shortcuts")

        root.frame = panel.contentView?.bounds ?? .zero
        root.autoresizingMask = [.width, .height]
        ShortcutUIStyle.configurePanelSurface(
            root,
            cornerRadius: ShortcutUIStyle.explainCornerRadius
        )
        panel.contentView = root
    }

    private func configureContent() {
        // Header
        iconImageView.image = AIShortcutsLogo.appIconImage(size: 42)
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.frame = NSRect(x: 28, y: 288, width: 42, height: 42)

        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = ShortcutUIStyle.primaryTextColor
        titleLabel.frame = NSRect(x: 82, y: 304, width: 400, height: 26)

        subtitleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        subtitleLabel.textColor = ShortcutUIStyle.secondaryTextColor
        subtitleLabel.frame = NSRect(x: 82, y: 284, width: 400, height: 18)

        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close welcome window"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        )
        closeButton.contentTintColor = ShortcutUIStyle.secondaryTextColor
        closeButton.frame = NSRect(x: 494, y: 298, width: 28, height: 28)
        closeButton.target = self
        closeButton.action = #selector(dismissFromButton)

        // Middle Card
        cardView.frame = NSRect(x: 28, y: 76, width: 494, height: 186)
        ShortcutUIStyle.configureContentSurface(cardView, cornerRadius: 12)

        // Card Item 1: Menu bar info
        menuBarIconView.image = NSImage(
            systemSymbolName: "menubar.arrow.up.rectangle",
            accessibilityDescription: "Menu bar"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        menuBarIconView.contentTintColor = ShortcutUIStyle.accentColor
        menuBarIconView.imageScaling = .scaleProportionallyDown
        menuBarIconView.frame = NSRect(x: 16, y: 140, width: 24, height: 24)

        menuBarTitleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        menuBarTitleLabel.textColor = ShortcutUIStyle.primaryTextColor
        menuBarTitleLabel.frame = NSRect(x: 50, y: 144, width: 424, height: 20)

        menuBarDescLabel.font = .systemFont(ofSize: 12, weight: .regular)
        menuBarDescLabel.textColor = ShortcutUIStyle.secondaryTextColor
        menuBarDescLabel.usesSingleLineMode = false
        menuBarDescLabel.maximumNumberOfLines = 2
        menuBarDescLabel.lineBreakMode = .byWordWrapping
        (menuBarDescLabel.cell as? NSTextFieldCell)?.wraps = true
        menuBarDescLabel.frame = NSRect(x: 50, y: 104, width: 424, height: 36)

        // Card Divider
        let divider = NSView(frame: NSRect(x: 16, y: 93, width: 462, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = ShortcutUIStyle.contentBorderColor.cgColor

        // Card Item 2: Setup info
        setupIconView.image = NSImage(
            systemSymbolName: "lock.shield.fill",
            accessibilityDescription: "Setup"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        setupIconView.contentTintColor = ShortcutUIStyle.successAccentColor
        setupIconView.imageScaling = .scaleProportionallyDown
        setupIconView.frame = NSRect(x: 16, y: 47, width: 24, height: 24)

        setupTitleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        setupTitleLabel.textColor = ShortcutUIStyle.primaryTextColor
        setupTitleLabel.frame = NSRect(x: 50, y: 51, width: 424, height: 20)

        setupDescLabel.font = .systemFont(ofSize: 12, weight: .regular)
        setupDescLabel.textColor = ShortcutUIStyle.secondaryTextColor
        setupDescLabel.usesSingleLineMode = false
        setupDescLabel.maximumNumberOfLines = 2
        setupDescLabel.lineBreakMode = .byWordWrapping
        (setupDescLabel.cell as? NSTextFieldCell)?.wraps = true
        setupDescLabel.frame = NSRect(x: 50, y: 11, width: 424, height: 36)

        cardView.addSubview(menuBarIconView)
        cardView.addSubview(menuBarTitleLabel)
        cardView.addSubview(menuBarDescLabel)
        cardView.addSubview(divider)
        cardView.addSubview(setupIconView)
        cardView.addSubview(setupTitleLabel)
        cardView.addSubview(setupDescLabel)

        // Footer: Checkbox & Buttons
        dontShowCheckbox.setButtonType(.switch)
        dontShowCheckbox.title = "Don't show this again"
        dontShowCheckbox.font = .systemFont(ofSize: 12, weight: .regular)
        dontShowCheckbox.contentTintColor = ShortcutUIStyle.secondaryTextColor
        dontShowCheckbox.frame = NSRect(x: 28, y: 24, width: 175, height: 22)
        dontShowCheckbox.target = self
        dontShowCheckbox.action = #selector(checkboxToggled)

        gotItButton.frame = NSRect(x: 246, y: 20, width: 72, height: 32)
        configureButton(
            gotItButton,
            title: "Got it",
            normalBackground: ShortcutUIStyle.raisedSurfaceColor,
            hoveredBackground: ShortcutUIStyle.raisedSurfaceColor.blended(withFraction: 0.12, of: .white)
                ?? ShortcutUIStyle.raisedSurfaceColor,
            tint: ShortcutUIStyle.secondaryTextColor,
            border: ShortcutUIStyle.contentBorderColor
        )
        gotItButton.target = self
        gotItButton.action = #selector(gotItClicked)

        settingsButton.frame = NSRect(x: 328, y: 20, width: 194, height: 32)
        configureButton(
            settingsButton,
            title: "Configure Model Settings",
            normalBackground: ShortcutUIStyle.accentColor.withAlphaComponent(0.88),
            hoveredBackground: ShortcutUIStyle.accentColor,
            tint: ShortcutUIStyle.primaryTextColor,
            border: ShortcutUIStyle.accentColor
        )
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)

        root.addSubview(iconImageView)
        root.addSubview(titleLabel)
        root.addSubview(subtitleLabel)
        root.addSubview(closeButton)
        root.addSubview(cardView)
        root.addSubview(dontShowCheckbox)
        root.addSubview(gotItButton)
        root.addSubview(settingsButton)
    }

    private func configureButton(
        _ button: WelcomeActionButton,
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
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: tint,
                .paragraphStyle: paragraphStyle,
            ]
        )
        button.setBackgroundColors(normal: normalBackground, hovered: hoveredBackground)
    }

    @objc private func checkboxToggled() {
        stateStore.welcomeDismissed = dontShowCheckbox.state == .on
    }

    @objc private func gotItClicked() {
        if dontShowCheckbox.state == .on {
            stateStore.welcomeDismissed = true
        }
        dismiss()
    }

    @objc private func settingsClicked() {
        if dontShowCheckbox.state == .on {
            stateStore.welcomeDismissed = true
        }
        dismiss()
        onOpenModelSettings?()
    }

    @objc private func dismissFromButton() {
        if dontShowCheckbox.state == .on {
            stateStore.welcomeDismissed = true
        }
        dismiss()
    }
}

private final class WelcomePanel: NSPanel {
    weak var owner: WelcomeWindowController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        owner?.dismiss()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            owner?.dismiss()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class WelcomeActionButton: NSButton {
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
