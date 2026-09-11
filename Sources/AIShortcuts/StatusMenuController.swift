import AppKit
import AIShortcutsCore
import Darwin

struct StatusMenuSnapshot {
    let busy: Bool
    let enabled: Bool
    let keyReady: Bool
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool
    let finderAutomationAuthorization: FinderAutomationAuthorization
    let lastAPIStatus: String
    let currentAction: String?
    let enabledShortcutActions: Set<AIShortcutAction>
    let providerSummary: String
}

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let snapshot: () -> StatusMenuSnapshot

    var onOpenWelcome: (() -> Void)?
    var onOpenModelSettings: (() -> Void)?
    var onReloadKey: (() -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?
    var onOpenScreenRecordingSettings: (() -> Void)?
    var onRequestFinderAutomation: (() -> Void)?
    var onCancelOperation: (() -> Void)?
    var onOpenShortcutGuide: (() -> Void)?
    var onToggleShortcut: ((AIShortcutAction, Bool) -> Void)?
    var onQuit: (() -> Void)?

    init(snapshot: @escaping () -> StatusMenuSnapshot) {
        self.snapshot = snapshot
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "AI Shortcuts"
        setBusy(false)
        rebuildMenu()
    }

    func setBusy(_ busy: Bool) {
        let image: NSImage
        if busy {
            image = NSImage(
                systemSymbolName: "ellipsis.circle",
                accessibilityDescription: "AI Shortcuts"
            ) ?? AIShortcutsLogo.menuBarImage()
        } else {
            image = AIShortcutsLogo.menuBarImage()
        }
        image.isTemplate = true
        statusItem.button?.image = image
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let state = snapshot()
        menu.removeAllItems()

        menu.addItem(disabledItem(StatusMenuPresentation.headline(
            busy: state.busy,
            enabled: state.enabled,
            currentAction: state.currentAction
        )))
        if state.busy {
            menu.addItem(actionItem(
                "Cancel Current Operation",
                action: #selector(cancelOperation)
            ))
        }

        menu.addItem(.separator())

        menu.addItem(disabledItem("Shortcuts"))
        for definition in HotKeyDefinition.defaults {
            menu.addItem(shortcutToggleItem(
                definition,
                enabled: state.enabledShortcutActions.contains(definition.action)
            ))
        }
        let welcome = actionItem(
            "Welcome & Setup…",
            action: #selector(openWelcome)
        )
        welcome.image = NSImage(
            systemSymbolName: "hand.wave",
            accessibilityDescription: "Welcome & Setup"
        )
        welcome.indentationLevel = 1
        menu.addItem(welcome)

        let guide = actionItem(
            "Shortcut Guide…",
            action: #selector(openShortcutGuide)
        )
        guide.image = NSImage(
            systemSymbolName: "info.circle",
            accessibilityDescription: "Shortcut Guide"
        )
        guide.indentationLevel = 1
        menu.addItem(guide)

        menu.addItem(.separator())
        menu.addItem(disabledItem("Readiness"))

        let modelSettings = actionItem(
            "Model Settings…",
            action: #selector(openModelSettings)
        )
        modelSettings.indentationLevel = 1
        menu.addItem(modelSettings)
        let modelItem = disabledItem("Model · \(state.providerSummary)")
        modelItem.indentationLevel = 1
        menu.addItem(modelItem)

        let key = disabledItem("API key · \(state.keyReady ? "Ready" : "Missing")")
        key.indentationLevel = 1
        menu.addItem(key)

        let apiStatus = disabledItem("Last request · \(state.lastAPIStatus)")
        apiStatus.indentationLevel = 1
        menu.addItem(apiStatus)

        let accessibilityTitle = state.accessibilityGranted
            ? "Accessibility · Granted"
            : "Accessibility · Grant Permission…"
        let accessibility = actionItem(
            accessibilityTitle,
            action: #selector(openAccessibilitySettings)
        )
        accessibility.isEnabled = !state.accessibilityGranted
        accessibility.indentationLevel = 1
        menu.addItem(accessibility)

        let screenTitle = state.screenRecordingGranted
            ? "Screen Recording · Granted"
            : "Screen Recording · Grant Permission…"
        let screen = actionItem(screenTitle, action: #selector(openScreenRecordingSettings))
        screen.isEnabled = !state.screenRecordingGranted
        screen.indentationLevel = 1
        menu.addItem(screen)

        let finderTitle: String
        switch state.finderAutomationAuthorization {
        case .unknown:
            finderTitle = "Finder Automation · Checking…"
        case .granted:
            finderTitle = "Finder Automation · Granted"
        case .notDetermined:
            finderTitle = "Finder Automation · Request Permission…"
        case .denied:
            finderTitle = "Finder Automation · Denied — Open Settings…"
        case .finderNotRunning:
            finderTitle = "Finder Automation · Open Finder, then retry"
        case .unavailable:
            finderTitle = "Finder Automation · Check Permission…"
        }
        let finderAutomation = actionItem(
            finderTitle,
            action: #selector(requestFinderAutomation)
        )
        finderAutomation.isEnabled = state.finderAutomationAuthorization != .granted
            && state.finderAutomationAuthorization != .unknown
        finderAutomation.indentationLevel = 1
        menu.addItem(finderAutomation)

        menu.addItem(.separator())
        menu.addItem(actionItem("Reload API Key", action: #selector(reloadKey)))
        menu.addItem(actionItem("Restart AI Shortcuts", action: #selector(restart)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit AI Shortcuts", action: #selector(quit)))
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func shortcutToggleItem(
        _ definition: HotKeyDefinition,
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let row = ShortcutToggleMenuRow(
            title: definition.action.displayName,
            shortcut: ShortcutUIStyle.shortcutLabel(for: definition),
            enabled: enabled
        )
        row.onToggle = { [weak self] enabled in
            self?.onToggleShortcut?(definition.action, enabled)
        }
        item.view = row
        return item
    }

    @objc private func openWelcome() {
        onOpenWelcome?()
    }

    @objc private func openModelSettings() {
        onOpenModelSettings?()
    }

    @objc private func reloadKey() {
        onReloadKey?()
    }

    @objc private func openAccessibilitySettings() {
        onOpenAccessibilitySettings?()
    }

    @objc private func openScreenRecordingSettings() {
        onOpenScreenRecordingSettings?()
    }

    @objc private func requestFinderAutomation() {
        onRequestFinderAutomation?()
    }

    @objc private func restart() {
        exit(EXIT_FAILURE)
    }

    @objc private func cancelOperation() {
        onCancelOperation?()
    }

    @objc private func openShortcutGuide() {
        onOpenShortcutGuide?()
    }

    @objc private func quit() {
        onQuit?()
    }
}

@MainActor
private final class ShortcutToggleMenuRow: NSView {
    var onToggle: ((Bool) -> Void)?

    private let checkmarkView = NSImageView()
    private let titleLabel: NSTextField
    private let shortcutLabel: NSTextField
    private var isEnabledState: Bool
    private var isHovered = false
    private var trackingAreaReference: NSTrackingArea?

    init(title: String, shortcut: String, enabled: Bool) {
        titleLabel = NSTextField(labelWithString: title)
        shortcutLabel = NSTextField(labelWithString: shortcut)
        isEnabledState = enabled
        super.init(frame: NSRect(x: 0, y: 0, width: 310, height: 22))

        wantsLayer = true
        layer?.cornerRadius = 5

        checkmarkView.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        )
        checkmarkView.imageScaling = .scaleProportionallyDown

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        shortcutLabel.font = .menuFont(ofSize: 0)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right

        addSubview(checkmarkView)
        addSubview(titleLabel)
        addSubview(shortcutLabel)
        updateAppearance()
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        checkmarkView.frame = NSRect(x: 13, y: 5, width: 12, height: 12)
        titleLabel.frame = NSRect(x: 34, y: 2, width: bounds.width - 142, height: 18)
        shortcutLabel.frame = NSRect(x: bounds.width - 104, y: 2, width: 88, height: 18)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        isEnabledState.toggle()
        updateAppearance()
        onToggle?(isEnabledState)
    }

    private func updateAppearance() {
        checkmarkView.isHidden = !isEnabledState
        setAccessibilityValue(isEnabledState ? 1 : 0)
        layer?.backgroundColor = isHovered
            ? NSColor.selectedContentBackgroundColor.cgColor
            : NSColor.clear.cgColor
        let primary: NSColor = isHovered ? .selectedMenuItemTextColor : .labelColor
        let secondary: NSColor = isHovered
            ? .selectedMenuItemTextColor.withAlphaComponent(0.82)
            : .secondaryLabelColor
        checkmarkView.contentTintColor = primary
        titleLabel.textColor = primary
        shortcutLabel.textColor = secondary
    }
}
