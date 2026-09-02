import AppKit
import AIShortcutsCore
import AIShortcutsRendering

@MainActor
final class ExplanationPanelController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private enum TranscriptScrollTarget {
        case top
        case latestUser(animated: Bool)
        case latestAnswer(animated: Bool)
        case end(animated: Bool)
    }

    private let panel: ExplainChatPanel
    private let transcriptView: RichTranscriptTextView
    private let transcriptScrollView: NSScrollView
    private let promptView: PasteAwareTextView
    private let promptScrollView: NSScrollView
    private let attachmentStrip: NSView
    private let headerTitleLabel: NSTextField
    private let contextLabel: NSTextField
    private let placeholderLabel: NSTextField
    private let composerSurface: NSView
    private let submitButton: NSButton
    private let progressIndicator: NSProgressIndicator
    private let richTextRenderer = NativeRichTextRenderer(
        theme: RichTextTheme(
            bodyFont: .systemFont(ofSize: 15),
            codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
            bodyColor: ShortcutUIStyle.primaryTextColor,
            secondaryColor: ShortcutUIStyle.secondaryTextColor,
            accentColor: ShortcutUIStyle.accentColor,
            codeBackgroundColor: ShortcutUIStyle.raisedSurfaceColor,
            tableBorderColor: ShortcutUIStyle.contentBorderColor
        )
    )

    private var submitHandler: ((String, [Data]) -> Void)?
    private var exchanges: [ExplanationExchange] = []
    private var pendingRequest: String?
    private var errorText: String?
    private var hasHiddenSelection = false
    private var isLoading = false
    private var transcriptScrollTarget: TranscriptScrollTarget = .top
    private var pastedImages: [ExplainPastedImage] = []

    private static let maximumPastedImages = 4

    var isVisible: Bool {
        panel.isVisible
    }

    override init() {
        panel = ExplainChatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        transcriptView = RichTranscriptTextView()
        transcriptScrollView = NSScrollView()
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
    }

    func show(
        exchanges: [ExplanationExchange],
        hasHiddenSelection: Bool,
        isLoading: Bool,
        pendingRequest: String? = nil,
        onSubmit: @escaping (String, [Data]) -> Void
    ) {
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
            ?? NSRect(x: mouse.x - 310, y: mouse.y - 170, width: 620, height: 340)
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
        headerTitleLabel.frame = NSRect(x: 22, y: 296, width: 120, height: 22)
        headerTitleLabel.setAccessibilityLabel("Explain")

        contextLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        contextLabel.textColor = ShortcutUIStyle.secondaryTextColor
        contextLabel.alignment = .right
        contextLabel.frame = NSRect(x: 150, y: 299, width: 448, height: 18)
        contextLabel.setAccessibilityLabel("Context")

        background.addSubview(headerTitleLabel)
        background.addSubview(contextLabel)
    }

    private func configureTranscript(in background: NSView) {
        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.drawsBackground = false
        transcriptView.isRichText = true
        transcriptView.importsGraphics = true
        transcriptView.isAutomaticLinkDetectionEnabled = false
        transcriptView.textContainerInset = NSSize(width: 4, height: 8)
        transcriptView.frame = NSRect(x: 0, y: 0, width: 584, height: 188)
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.textContainer?.containerSize = NSSize(
            width: 600,
            height: CGFloat.greatestFiniteMagnitude
        )

        transcriptScrollView.frame = NSRect(x: 18, y: 92, width: 584, height: 188)
        transcriptScrollView.autoresizingMask = [.width, .height]
        transcriptScrollView.hasVerticalScroller = true
        transcriptScrollView.scrollerStyle = .overlay
        transcriptScrollView.drawsBackground = false
        transcriptScrollView.documentView = transcriptView
        background.addSubview(transcriptScrollView)
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
        transcriptScrollView.frame = hasImages
            ? NSRect(x: 18, y: 142, width: 584, height: 138)
            : NSRect(x: 18, y: 92, width: 584, height: 188)
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
        let rendered = NSMutableAttributedString()
        var richSourceSegments: [RichTranscriptSourceSegment] = []
        var latestUserRange: NSRange?
        var latestAssistantRange: NSRange?
        for exchange in exchanges {
            if !exchange.request.isEmpty {
                latestUserRange = appendUserText(exchange.request, to: rendered)
            }
            latestAssistantRange = appendAssistantText(
                exchange.explanation,
                to: rendered,
                sourceSegments: &richSourceSegments
            )
        }

        if let pendingRequest, !pendingRequest.isEmpty {
            latestUserRange = appendUserText(pendingRequest, to: rendered)
        }
        var statusRange: NSRange?
        if isLoading {
            statusRange = appendStatus(
                "Thinking…",
                color: ShortcutUIStyle.secondaryTextColor,
                to: rendered
            )
        } else if let errorText {
            statusRange = appendStatus(
                errorText,
                color: ShortcutUIStyle.warningAccentColor,
                to: rendered
            )
        }

        transcriptView.textStorage?.setAttributedString(rendered)
        transcriptView.sourceSegments = richSourceSegments
        let viewportHeight = transcriptScrollView.contentView.bounds.height
        let contentHeight = NativeTextViewLayout.fitDocumentView(
            transcriptView,
            minimumHeight: viewportHeight
        )
        transcriptScrollView.hasVerticalScroller = contentHeight > viewportHeight + 0.5
        switch transcriptScrollTarget {
        case .top:
            scrollTranscriptToTop()
        case let .latestUser(animated):
            if let latestUserRange {
                scrollTranscript(to: latestUserRange, leadingInset: 18, animated: animated)
            } else {
                scrollTranscriptToTop()
            }
        case let .latestAnswer(animated):
            if let latestAssistantRange {
                scrollTranscript(to: latestAssistantRange, leadingInset: 8, animated: animated)
            } else {
                scrollTranscriptToTop()
            }
        case let .end(animated):
            if let range = statusRange ?? latestAssistantRange ?? latestUserRange {
                scrollTranscript(to: range, leadingInset: 8, animated: animated)
            } else {
                scrollTranscriptToTop()
            }
        }
    }

    @discardableResult
    private func appendAssistantText(
        _ document: AIOutputDocument,
        to rendered: NSMutableAttributedString,
        sourceSegments: inout [RichTranscriptSourceSegment]
    ) -> NSRange {
        let start = rendered.length
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 10
        paragraph.paragraphSpacing = 8
        paragraph.lineSpacing = 5
        paragraph.firstLineHeadIndent = 4
        paragraph.headIndent = 4
        paragraph.tailIndent = -18
        rendered.append(
            NSAttributedString(
                string: "Explain\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: ShortcutUIStyle.secondaryTextColor,
                    .paragraphStyle: paragraph,
                ]
            )
        )
        let richOutput = richTextRenderer.render(document)
        let contentStart = rendered.length
        rendered.append(richOutput.attributedString)
        sourceSegments.append(
            RichTranscriptSourceSegment(
                renderedRange: NSRange(
                    location: contentStart,
                    length: richOutput.attributedString.length
                ),
                payload: richOutput.clipboardPayload
            )
        )
        rendered.append(
            NSAttributedString(
                string: "\n",
                attributes: [.paragraphStyle: paragraph]
            )
        )
        return NSRange(location: start, length: rendered.length - start)
    }

    private func scrollTranscript(
        to range: NSRange,
        leadingInset: CGFloat,
        animated: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let layoutManager = transcriptView.layoutManager,
                  let textContainer = transcriptView.textContainer
            else {
                return
            }
            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            let targetRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            let clipView = transcriptScrollView.contentView
            let maximumY = max(0, transcriptView.bounds.height - clipView.bounds.height)
            let target = NSPoint(
                x: clipView.bounds.origin.x,
                y: min(max(0, targetRect.minY - leadingInset), maximumY)
            )
            guard animated else {
                clipView.setBoundsOrigin(target)
                transcriptScrollView.reflectScrolledClipView(clipView)
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                clipView.animator().setBoundsOrigin(target)
            } completionHandler: {
                Task { @MainActor [weak self] in
                    self?.transcriptScrollView.reflectScrolledClipView(clipView)
                }
            }
        }
    }

    private func scrollTranscriptToTop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            let clipView = transcriptScrollView.contentView
            clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: 0))
            transcriptScrollView.reflectScrolledClipView(clipView)
        }
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

    @discardableResult
    private func appendUserText(
        _ text: String,
        to rendered: NSMutableAttributedString
    ) -> NSRange {
        let start = rendered.length
        let block = UserPromptTextBlock()
        block.setContentWidth(96, type: .percentageValueType)
        block.setWidth(8, type: .absoluteValueType, for: .padding)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)

        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = [block]
        paragraph.paragraphSpacing = 8
        paragraph.lineSpacing = 4
        rendered.append(
            NSAttributedString(
                string: "You\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: ShortcutUIStyle.accentColor,
                    .paragraphStyle: paragraph,
                ]
            )
        )
        rendered.append(
            NSAttributedString(
                string: "\(text)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15),
                    .foregroundColor: ShortcutUIStyle.primaryTextColor,
                    .paragraphStyle: paragraph,
                ]
            )
        )
        return NSRange(location: start, length: rendered.length - start)
    }

    @discardableResult
    private func appendStatus(
        _ text: String,
        color: NSColor,
        to rendered: NSMutableAttributedString
    ) -> NSRange {
        let start = rendered.length
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 10
        paragraph.paragraphSpacing = 8
        paragraph.lineSpacing = 5
        paragraph.firstLineHeadIndent = 4
        paragraph.headIndent = 4
        paragraph.tailIndent = -18
        rendered.append(
            NSAttributedString(
                string: "Explain\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: ShortcutUIStyle.secondaryTextColor,
                    .paragraphStyle: paragraph,
                ]
            )
        )
        rendered.append(
            NSAttributedString(
                string: "\(text)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ]
            )
        )
        return NSRange(location: start, length: rendered.length - start)
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

private struct RichTranscriptSourceSegment {
    let renderedRange: NSRange
    let payload: RichClipboardPayload
}

private final class RichTranscriptTextView: NSTextView {
    var sourceSegments: [RichTranscriptSourceSegment] = []

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        if let segment = sourceSegments.first(where: {
            NSEqualRanges($0.renderedRange, selection)
        }) {
            segment.payload.write(to: NSPasteboard.general)
            return
        }
        super.copy(sender)
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

private final class UserPromptTextBlock: NSTextBlock {
    override func drawBackground(
        withFrame frameRect: NSRect,
        in controlView: NSView,
        characterRange charRange: NSRange,
        layoutManager: NSLayoutManager
    ) {
        let backgroundRect = frameRect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: backgroundRect,
            xRadius: 11,
            yRadius: 11
        )
        NSColor(
            srgbRed: 0.155,
            green: 0.150,
            blue: 0.205,
            alpha: 1
        ).setFill()
        path.fill()
        NSColor(
            srgbRed: 0.500,
            green: 0.455,
            blue: 0.985,
            alpha: 0.34
        ).setStroke()
        path.lineWidth = 1
        path.stroke()
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
