import AppKit
import AIShortcutsCore

@MainActor
final class ShortcutGuideWindowController: NSObject, NSWindowDelegate {
    private let panel: ShortcutGuidePanel
    private let root = NSView()
    private let titleLabel = NSTextField(labelWithString: "Shortcut Guide")
    private let subtitleLabel = NSTextField(
        labelWithString: "What each shortcut does, where its result goes, and what access it needs"
    )
    private let closeButton = NSButton()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = ShortcutGuidePanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 610),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
        configureContent()
    }

    func show() {
        textView.textStorage?.setAttributedString(makeGuideText())
        textView.scrollToBeginningOfDocument(nil)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Keep the guide available while the owner switches apps to compare
        // behavior. It closes only through its close control or Escape.
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
        panel.setAccessibilityLabel("AI Shortcuts guide")

        root.frame = panel.contentView?.bounds ?? .zero
        root.autoresizingMask = [.width, .height]
        ShortcutUIStyle.configurePanelSurface(
            root,
            cornerRadius: ShortcutUIStyle.explainCornerRadius
        )
        panel.contentView = root
    }

    private func configureContent() {
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = ShortcutUIStyle.primaryTextColor
        titleLabel.frame = NSRect(x: 26, y: 562, width: 300, height: 26)

        subtitleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        subtitleLabel.textColor = ShortcutUIStyle.secondaryTextColor
        subtitleLabel.frame = NSRect(x: 26, y: 538, width: 600, height: 18)

        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close shortcut guide"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        )
        closeButton.contentTintColor = ShortcutUIStyle.secondaryTextColor
        closeButton.frame = NSRect(x: 647, y: 560, width: 30, height: 30)
        closeButton.target = self
        closeButton.action = #selector(closeGuide)

        scrollView.frame = NSRect(x: 20, y: 20, width: 660, height: 506)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = ShortcutUIStyle.inputCornerRadius
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = ShortcutUIStyle.contentBorderColor.cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 1_200)
        textView.minSize = NSSize(width: 0, height: 506)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.drawsBackground = true
        textView.backgroundColor = ShortcutUIStyle.raisedSurfaceColor
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 640,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityLabel("Available shortcut explanations")
        scrollView.documentView = textView

        root.addSubview(titleLabel)
        root.addSubview(subtitleLabel)
        root.addSubview(closeButton)
        root.addSubview(scrollView)
    }

    private func makeGuideText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let definitions = Dictionary(
            uniqueKeysWithValues: HotKeyDefinition.defaults.map { ($0.action, $0) }
        )
        for (index, action) in AIShortcutAction.allCases.enumerated() {
            guard let definition = definitions[action] else {
                continue
            }
            let guide = guideContent(for: action)
            let headerParagraph = NSMutableParagraphStyle()
            headerParagraph.tabStops = [
                NSTextTab(textAlignment: .right, location: 610),
            ]
            headerParagraph.defaultTabInterval = 610
            headerParagraph.paragraphSpacing = 7
            result.append(NSAttributedString(
                string: "\(action.displayName)\t\(ShortcutUIStyle.shortcutLabel(for: definition))\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15.5, weight: .semibold),
                    .foregroundColor: ShortcutUIStyle.primaryTextColor,
                    .paragraphStyle: headerParagraph,
                ]
            ))

            let bodyParagraph = NSMutableParagraphStyle()
            bodyParagraph.lineSpacing = 2
            bodyParagraph.paragraphSpacing = 8
            result.append(NSAttributedString(
                string: "\(guide.summary)\n\(guide.output)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13.2, weight: .regular),
                    .foregroundColor: ShortcutUIStyle.secondaryTextColor,
                    .paragraphStyle: bodyParagraph,
                ]
            ))

            let permissionParagraph = NSMutableParagraphStyle()
            permissionParagraph.paragraphSpacing = index == AIShortcutAction.allCases.count - 1 ? 0 : 18
            result.append(NSAttributedString(
                string: "Access · \(guide.access)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.8, weight: .semibold),
                    .foregroundColor: ShortcutUIStyle.accentColor,
                    .paragraphStyle: permissionParagraph,
                ]
            ))
        }
        return result
    }

    private func guideContent(
        for action: AIShortcutAction
    ) -> (summary: String, output: String, access: String) {
        switch action {
        case .ocr:
            return (
                "Drag over any screen area to transcribe all visible text.",
                "Result · Literal plain text is copied; the screenshot is not retained.",
                "Screen Recording + OpenAI"
            )
        case .refine:
            return (
                "Correct spelling, grammar, and awkward wording in selected text without changing its language.",
                "Result · Preserves detected Markdown/equation mode; replaces an unchanged selection or copies the revision.",
                "Accessibility + OpenAI"
            )
        case .translate:
            return (
                "Translate selected text using a free-form target such as “Japanese, formal”.",
                "Result · Preserves detected Markdown/equation mode, copies the translation, and leaves the original selection untouched.",
                "Accessibility + OpenAI"
            )
        case .format:
            return (
                "Restructure selected text using a short instruction such as “concise email with bullets”.",
                "Result · Uses guarded Markdown for structured requests; safely replaces an unchanged selection or copies the result.",
                "Accessibility + OpenAI"
            )
        case .finderPath:
            return (
                "Copy the complete POSIX path of the selected Finder file or folder.",
                "Result · Copies one path per selected item; no AI request is made.",
                "Finder Automation"
            )
        case .explain:
            return (
                "Ask about hidden selected text, type a general question, or paste up to four images.",
                "Result · Assistant answers render guarded Markdown and common LaTeX in a selectable conversation with transient one-hour context.",
                "Accessibility + OpenAI"
            )
        case .calculate:
            return (
                "Crop visual data and optionally describe the calculation or extraction you need.",
                "Result · Shows a selectable, scrollable rich answer until the cursor moves away and copies its source plus rich clipboard formats.",
                "Screen Recording + OpenAI"
            )
        case .inputLock:
            return (
                "Choose Keyboard Lock or Shortcut Lock to temporarily suppress keyboard interpretation.",
                "Result · The same shortcut restores input; quitting or crashing also removes the lock.",
                "Accessibility · local only"
            )
        case .clipboardQueue:
            return (
                "Collect several normal ⌘C copies, switch modes, then paste them in FIFO order with ⌘V.",
                "Result · The temporary queue clears when empty or cancelled and is never persisted.",
                "Accessibility · local only"
            )
        case .insert:
            return (
                "Insert a saved value by key. Use /new, /modify, or /delete in the same adaptive panel.",
                "Result · Pastes into the original field and restores your clipboard; only ambiguous key labels use AI.",
                "Accessibility; OpenAI only for smart matching"
            )
        }
    }

    @objc private func closeGuide() {
        dismiss()
    }
}

private final class ShortcutGuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
