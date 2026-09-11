import AppKit
import AIShortcutsCore
import AIShortcutsRendering
import WebKit

@MainActor
final class ExplanationPanelController: NSObject, NSWindowDelegate, NSTextViewDelegate, WKNavigationDelegate {
    private enum TranscriptScrollTarget {
        case top
        case latestUser(animated: Bool)
        case latestAnswer(animated: Bool)
        case end(animated: Bool)
    }

    private let panel: ExplainChatPanel
    private let transcriptView: WKWebView
    private let promptView: PasteAwareTextView
    private let promptScrollView: NSScrollView
    private let attachmentStrip: NSView
    private let headerTitleLabel: NSTextField
    private let contextLabel: NSTextField
    private let placeholderLabel: NSTextField
    private let composerSurface: NSView
    private let submitButton: NSButton
    private let progressIndicator: NSProgressIndicator
    private let webTextRenderer = WebRichTextRenderer()

    private var submitHandler: ((String, [Data]) -> Void)?
    private var exchanges: [ExplanationExchange] = []
    private var pendingRequest: String?
    private var errorText: String?
    private var hasHiddenSelection = false
    private var isLoading = false
    private var transcriptScrollTarget: TranscriptScrollTarget = .top
    private var pastedImages: [ExplainPastedImage] = []
    private var latestUserAnchor: String?
    private var latestAssistantAnchor: String?
    private var statusAnchor: String?
    private var hasPreparedWebView = false

    private static let maximumPastedImages = 4

    var isVisible: Bool {
        panel.isVisible
    }

    override init() {
        panel = ExplainChatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 390),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfiguration.websiteDataStore = .nonPersistent()
        transcriptView = WKWebView(frame: .zero, configuration: webConfiguration)
        promptView = PasteAwareTextView()
        promptScrollView = NSScrollView()
        attachmentStrip = NSView()
        headerTitleLabel = NSTextField(labelWithString: "Explain")
        contextLabel = NSTextField(labelWithString: "General chat")
        placeholderLabel = NSTextField(labelWithString: "Ask anything…")
        composerSurface = NSView(frame: NSRect(x: 14, y: 14, width: 592, height: 66))
        submitButton = NSButton(frame: NSRect(x: 538, y: 15, width: 36, height: 36))
        progressIndicator = NSProgressIndicator()
        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.setAccessibilityLabel("Explain")

        let background = ExplainSurfaceView(frame: panel.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]

        configureHeader(in: background)
        configureTranscript(in: background)
        configureComposer(in: background)
        panel.contentView = background
        updateComposerLayout()
    }

    func prepare() {
        guard !hasPreparedWebView else {
            return
        }
        hasPreparedWebView = true
        transcriptView.loadHTMLString(
            webTextRenderer.htmlDocument(body: #"<main class="transcript"></main>"#),
            baseURL: webTextRenderer.resourceBaseURL
        )
    }

    func show(
        exchanges: [ExplanationExchange],
        hasHiddenSelection: Bool,
        isLoading: Bool,
        pendingRequest: String? = nil,
        onSubmit: @escaping (String, [Data]) -> Void
    ) {
        hasPreparedWebView = true
        self.exchanges = exchanges
        self.hasHiddenSelection = hasHiddenSelection
        self.isLoading = isLoading
        self.pendingRequest = pendingRequest
        if isLoading, pendingRequest != nil {
            transcriptScrollTarget = .latestUser(animated: false)
        } else if exchanges.isEmpty {
            transcriptScrollTarget = .top
        } else {
            transcriptScrollTarget = .latestAnswer(animated: false)
        }
        submitHandler = onSubmit
        updateInterface()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(
                x: mouse.x - panel.frame.width / 2,
                y: mouse.y - panel.frame.height / 2,
                width: panel.frame.width,
                height: panel.frame.height
            )
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.midY - panel.frame.height / 2
            )
        )

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !isLoading {
            panel.makeFirstResponder(promptView)
        }
        resetComposerScrollPosition()
    }

    func setLoading(request: String, imageCount: Int) {
        pendingRequest = Self.displayRequest(request, imageCount: imageCount)
        errorText = nil
        isLoading = true
        promptView.string = ""
        pastedImages.removeAll()
        transcriptScrollTarget = .latestUser(animated: false)
        updateInterface()
        resetComposerScrollPosition()
    }

    func complete(with exchanges: [ExplanationExchange]) {
        self.exchanges = exchanges
        pendingRequest = nil
        errorText = nil
        hasHiddenSelection = false
        isLoading = false
        transcriptScrollTarget = .latestAnswer(animated: panel.isVisible)
        updateInterface()
        if panel.isVisible {
            panel.makeFirstResponder(promptView)
        }
    }

    func showError(
        _ message: String,
        retryRequest: String? = nil,
        retryImagePNGs: [Data] = [],
        hasHiddenSelection: Bool = false
    ) {
        pendingRequest = nil
        errorText = message
        isLoading = false
        transcriptScrollTarget = .end(animated: false)
        if let retryRequest {
            promptView.string = retryRequest
            pastedImages = retryImagePNGs.compactMap(ExplainPastedImage.init(pngData:))
            self.hasHiddenSelection = hasHiddenSelection
        }
        updateInterface()
        resetComposerScrollPosition()
        if panel.isVisible {
            panel.makeFirstResponder(promptView)
        }
    }

    func resetDraft() {
        promptView.string = ""
        pastedImages.removeAll()
        updateComposerLayout()
        updatePlaceholder()
        resetComposerScrollPosition()
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    func releaseResources() {
        panel.orderOut(nil)
        transcriptView.stopLoading()
        transcriptView.navigationDelegate = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
        updateSubmitButton()
    }

    func textDidBeginEditing(_ notification: Notification) {
        setComposerFocused(true)
    }

    func textDidEndEditing(_ notification: Notification) {
        setComposerFocused(false)
    }

    func textView(
        _ textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) {
                return false
            }
            submit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }

    private func configureHeader(in background: NSView) {
        headerTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        headerTitleLabel.textColor = ShortcutUIStyle.primaryTextColor
        headerTitleLabel.frame = NSRect(x: 22, y: 346, width: 120, height: 22)
        headerTitleLabel.setAccessibilityLabel("Explain")

        contextLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        contextLabel.textColor = ShortcutUIStyle.secondaryTextColor
        contextLabel.alignment = .right
        contextLabel.frame = NSRect(x: 150, y: 349, width: 448, height: 18)
        contextLabel.setAccessibilityLabel("Context")

        background.addSubview(headerTitleLabel)
        background.addSubview(contextLabel)
    }

    private func configureTranscript(in background: NSView) {
        transcriptView.navigationDelegate = self
        transcriptView.setValue(false, forKey: "drawsBackground")
        transcriptView.wantsLayer = true
        transcriptView.layer?.backgroundColor = NSColor.clear.cgColor
        transcriptView.setAccessibilityLabel("Explanation transcript")
        transcriptView.frame = NSRect(x: 0, y: 0, width: 584, height: 188)
        transcriptView.autoresizingMask = [.width, .height]
        background.addSubview(transcriptView)
    }

    private func configureComposer(in background: NSView) {
        composerSurface.autoresizingMask = [.width, .maxYMargin]
        ShortcutUIStyle.configureContentSurface(
            composerSurface,
            cornerRadius: ShortcutUIStyle.inputCornerRadius
        )
        composerSurface.setAccessibilityLabel("Explain prompt")

        promptView.delegate = self
        promptView.drawsBackground = false
        promptView.isRichText = false
        promptView.font = .systemFont(ofSize: 15.5)
        promptView.textColor = ShortcutUIStyle.primaryTextColor
        promptView.insertionPointColor = ShortcutUIStyle.accentColor
        promptView.textContainerInset = NSSize(width: 2, height: 14)
        promptView.isVerticallyResizable = true
        promptView.isHorizontallyResizable = false
        promptView.textContainer?.widthTracksTextView = true
        promptView.textContainer?.containerSize = NSSize(
            width: 506,
            height: CGFloat.greatestFiniteMagnitude
        )
        promptView.setAccessibilityLabel("Question")
        promptView.setAccessibilityHelp("Press Return to send, Shift-Return for a new line, or Escape to dismiss.")
        promptView.onPasteImages = { [weak self] images in
            self?.addPastedImages(images)
        }

        promptScrollView.frame = NSRect(x: 14, y: 7, width: 510, height: 52)
        promptScrollView.drawsBackground = false
        promptScrollView.hasVerticalScroller = false
        promptScrollView.documentView = promptView
        promptView.frame = promptScrollView.contentView.bounds
        promptView.autoresizingMask = [.width]
        composerSurface.addSubview(promptScrollView)

        attachmentStrip.frame = NSRect(x: 14, y: 64, width: 510, height: 44)
        attachmentStrip.isHidden = true
        attachmentStrip.setAccessibilityLabel("Image attachments")
        composerSurface.addSubview(attachmentStrip)

        placeholderLabel.font = .systemFont(ofSize: 15.5)
        placeholderLabel.textColor = ShortcutUIStyle.placeholderTextColor
        placeholderLabel.frame = NSRect(x: 18, y: 23, width: 420, height: 20)
        placeholderLabel.setAccessibilityLabel("Question hint")
        composerSurface.addSubview(placeholderLabel)

        submitButton.isBordered = false
        submitButton.focusRingType = .none
        submitButton.imagePosition = .imageOnly
        submitButton.imageScaling = .scaleProportionallyDown
        submitButton.image = NSImage(
            systemSymbolName: "arrow.up",
            accessibilityDescription: "Send"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        )
        submitButton.contentTintColor = ShortcutUIStyle.shellColor
        submitButton.wantsLayer = true
        submitButton.layer?.cornerRadius = 18
        submitButton.layer?.backgroundColor = ShortcutUIStyle.primaryTextColor.cgColor
        submitButton.target = self
        submitButton.action = #selector(submitFromButton)
        submitButton.setAccessibilityLabel("Send")
        submitButton.setAccessibilityHelp("Sends the question. Return also sends.")
        composerSurface.addSubview(submitButton)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.frame = NSRect(x: 547, y: 24, width: 18, height: 18)
        progressIndicator.isDisplayedWhenStopped = false
        composerSurface.addSubview(progressIndicator)
        background.addSubview(composerSurface)
    }

    @objc private func submitFromButton() {
        submit()
    }

    private func submit() {
        guard !isLoading else {
            return
        }
        let request = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty || hasHiddenSelection || !pastedImages.isEmpty else {
            return
        }
        submitHandler?(request, pastedImages.map(\.pngData))
    }

    private func updateInterface() {
        updateComposerLayout()
        renderTranscript()
        renderAttachmentStrip()
        promptView.isEditable = !isLoading
        promptView.textColor = isLoading
            ? ShortcutUIStyle.secondaryTextColor
            : ShortcutUIStyle.primaryTextColor
        if isLoading {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        submitButton.isHidden = isLoading
        updateHeader()
        updatePlaceholder()
        updateSubmitButton()
    }

    private func updateHeader() {
        let imageCount = pastedImages.count
        if hasHiddenSelection, imageCount > 0 {
            contextLabel.stringValue = "Selection + \(imageCount) image\(imageCount == 1 ? "" : "s") attached"
        } else if hasHiddenSelection {
            contextLabel.stringValue = "Selection attached · stays hidden"
        } else if imageCount > 0 {
            contextLabel.stringValue = "\(imageCount) image\(imageCount == 1 ? "" : "s") attached"
        } else {
            contextLabel.stringValue = "General chat"
        }
        contextLabel.textColor = hasHiddenSelection || imageCount > 0
            ? ShortcutUIStyle.accentColor.withAlphaComponent(0.92)
            : ShortcutUIStyle.secondaryTextColor
    }

    private func updatePlaceholder() {
        placeholderLabel.stringValue = hasHiddenSelection || !pastedImages.isEmpty
            ? "Ask about attachments…"
            : "Ask anything…"
        placeholderLabel.isHidden = !promptView.string.isEmpty || isLoading
    }

    private func updateSubmitButton() {
        let hasRequest = !promptView.string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        submitButton.isEnabled = !isLoading
            && (hasRequest || hasHiddenSelection || !pastedImages.isEmpty)
        submitButton.alphaValue = submitButton.isEnabled ? 1 : 0.34
    }

    private func addPastedImages(_ images: [NSImage]) {
        let remaining = max(0, Self.maximumPastedImages - pastedImages.count)
        let additions = images.prefix(remaining).compactMap(ExplainPastedImage.init(image:))
        guard !additions.isEmpty else {
            NSSound.beep()
            return
        }
        pastedImages.append(contentsOf: additions)
        renderAttachmentStrip()
        updateComposerLayout()
        updateHeader()
        updatePlaceholder()
        updateSubmitButton()
        panel.makeFirstResponder(promptView)
    }

    @objc private func removePastedImage(_ sender: NSButton) {
        guard pastedImages.indices.contains(sender.tag) else {
            return
        }
        pastedImages.remove(at: sender.tag)
        renderAttachmentStrip()
        updateComposerLayout()
        updateHeader()
        updatePlaceholder()
        updateSubmitButton()
        panel.makeFirstResponder(promptView)
    }

    private func renderAttachmentStrip() {
        attachmentStrip.subviews.forEach { $0.removeFromSuperview() }
        for (index, attachment) in pastedImages.enumerated() {
            let card = NSView(frame: NSRect(x: CGFloat(index) * 54, y: 0, width: 48, height: 44))
            card.wantsLayer = true
            card.layer?.cornerRadius = 8
            card.layer?.borderWidth = 1
            card.layer?.borderColor = ShortcutUIStyle.contentBorderColor.cgColor
            card.layer?.backgroundColor = ShortcutUIStyle.shellColor.cgColor

            let imageView = NSImageView(frame: NSRect(x: 2, y: 2, width: 40, height: 40))
            imageView.image = attachment.preview
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 6
            imageView.layer?.masksToBounds = true
            imageView.setAccessibilityLabel("Pasted image \(index + 1)")
            card.addSubview(imageView)

            let remove = NSButton(frame: NSRect(x: 32, y: 28, width: 16, height: 16))
            remove.isBordered = false
            remove.imagePosition = .imageOnly
            remove.image = NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: "Remove image"
            )
            remove.contentTintColor = ShortcutUIStyle.primaryTextColor
            remove.target = self
            remove.action = #selector(removePastedImage(_:))
            remove.tag = index
            card.addSubview(remove)
            attachmentStrip.addSubview(card)
        }
        attachmentStrip.isHidden = pastedImages.isEmpty
    }

    private func updateComposerLayout() {
        let hasImages = !pastedImages.isEmpty
        composerSurface.frame.size.height = hasImages ? 116 : 66
        attachmentStrip.isHidden = !hasImages

        guard let contentView = panel.contentView else {
            return
        }
        let contentHeight = contentView.bounds.height
        headerTitleLabel.frame.origin.y = contentHeight - 44
        contextLabel.frame.origin.y = contentHeight - 41

        let transcriptOriginY = composerSurface.frame.maxY + 12
        let transcriptCeiling = headerTitleLabel.frame.minY - 16
        transcriptView.frame = NSRect(
            x: 18,
            y: transcriptOriginY,
            width: contentView.bounds.width - 36,
            height: max(80, transcriptCeiling - transcriptOriginY)
        )
    }

    private static func displayRequest(_ request: String, imageCount: Int) -> String {
        let attachmentLabel = imageCount == 1 ? "Image attached" : "\(imageCount) images attached"
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard imageCount > 0 else {
            return trimmed
        }
        return trimmed.isEmpty ? attachmentLabel : "\(trimmed)\n\(attachmentLabel)"
    }

    private func setComposerFocused(_ focused: Bool) {
        composerSurface.layer?.borderWidth = focused ? 1.5 : 1
        composerSurface.layer?.borderColor = focused
            ? ShortcutUIStyle.focusBorderColor.cgColor
            : ShortcutUIStyle.contentBorderColor.cgColor
    }

    private func renderTranscript() {
        var body = "<main class=\"transcript\">"
        var messageIndex = 0
        latestUserAnchor = nil
        latestAssistantAnchor = nil
        statusAnchor = nil

        for exchange in exchanges {
            if !exchange.request.isEmpty {
                let anchor = "user-\(messageIndex)"
                latestUserAnchor = anchor
                body += "<section class=\"message-user\" id=\"\(anchor)\">"
                body += webTextRenderer.renderPlainText(exchange.request)
                body += "</section>"
                messageIndex += 1
            }
            let anchor = "assistant-\(messageIndex)"
            latestAssistantAnchor = anchor
            body += "<article class=\"message-assistant\" id=\"\(anchor)\">"
            body += webTextRenderer.render(exchange.explanation)
            body += "</article>"
            messageIndex += 1
        }

        if let pendingRequest, !pendingRequest.isEmpty {
            let anchor = "user-\(messageIndex)"
            latestUserAnchor = anchor
            body += "<section class=\"message-user\" id=\"\(anchor)\">"
            body += webTextRenderer.renderPlainText(pendingRequest)
            body += "</section>"
            messageIndex += 1
        }
        if isLoading {
            statusAnchor = "status"
            body += "<div class=\"status\" id=\"status\">"
            body += webTextRenderer.renderPlainText("Thinking…")
            body += "</div>"
        } else if let errorText {
            statusAnchor = "status"
            body += "<div class=\"status error\" id=\"status\">"
            body += webTextRenderer.renderPlainText(errorText)
            body += "</div>"
        }

        body += "</main>"
        transcriptView.loadHTMLString(
            webTextRenderer.htmlDocument(body: body),
            baseURL: webTextRenderer.resourceBaseURL
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyTranscriptScrollTarget()
    }

    private func applyTranscriptScrollTarget() {
        let anchor: String?
        let animated: Bool
        switch transcriptScrollTarget {
        case .top:
            anchor = nil
            animated = false
        case let .latestUser(isAnimated):
            anchor = latestUserAnchor
            animated = isAnimated
        case let .latestAnswer(isAnimated):
            anchor = latestAssistantAnchor
            animated = isAnimated
        case let .end(isAnimated):
            anchor = statusAnchor ?? latestAssistantAnchor ?? latestUserAnchor
            animated = isAnimated
        }

        let behavior = animated ? "smooth" : "auto"
        let anchorScript: String
        if let anchor {
            anchorScript = """
            const target = document.getElementById('\(anchor)');
            if (target) {
              const top = target.getBoundingClientRect().top + window.scrollY;
              window.scrollTo({ top: Math.max(0, top), behavior: '\(behavior)' });
              return;
            }
            """
        } else {
            anchorScript = ""
        }
        transcriptView.evaluateJavaScript("""
        (() => {
          \(anchorScript)
          window.scrollTo({ top: 0, behavior: 'auto' });
        })();
        """)
    }

    private func resetComposerScrollPosition() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            let clipView = promptScrollView.contentView
            clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: 0))
            promptScrollView.reflectScrolledClipView(clipView)
        }
    }

}

private struct ExplainPastedImage {
    let pngData: Data
    let preview: NSImage

    init?(image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }
        self.pngData = pngData
        preview = image
    }

    init?(pngData: Data) {
        guard let image = NSImage(data: pngData) else {
            return nil
        }
        self.pngData = pngData
        preview = image
    }
}

private final class PasteAwareTextView: NSTextView {
    var onPasteImages: (([NSImage]) -> Void)?

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let images = pasteboard.readObjects(
            forClasses: [NSImage.self],
            options: nil
        ) as? [NSImage] ?? []
        if !images.isEmpty {
            onPasteImages?(images)
            return
        }
        if let image = NSImage(pasteboard: pasteboard) {
            onPasteImages?([image])
            return
        }
        super.paste(sender)
    }
}

private final class ExplainSurfaceView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ShortcutUIStyle.configurePanelSurface(
            self,
            cornerRadius: ShortcutUIStyle.explainCornerRadius
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateLayer() {
        layer?.backgroundColor = ShortcutUIStyle.shellColor.cgColor
        layer?.borderColor = ShortcutUIStyle.panelBorderColor.cgColor
    }
}

private final class ExplainChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }
}
