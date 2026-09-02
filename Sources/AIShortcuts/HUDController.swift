import AppKit
import AIShortcutsCore

@MainActor
final class HUDController {
    private enum Presentation: Equatable {
        case compact
        case result
    }

    @MainActor
    private enum Tone {
        case success
        case busy
        case warning

        var accentColor: NSColor {
            switch self {
            case .success:
                ShortcutUIStyle.successAccentColor
            case .busy:
                ShortcutUIStyle.accentColor
            case .warning:
                ShortcutUIStyle.warningAccentColor
            }
        }
    }

    private var panel: NSPanel?
    private var generation = 0
    private var dismissOnMouseExit = false
    private var mouseExitPoller: DispatchSourceTimer?

    func showSuccess(text: String? = nil) {
        show(
            symbolName: "checkmark",
            text: text,
            tone: .success,
            duration: 0.9,
            presentation: .compact
        )
    }

    func showResult(text: String) {
        show(
            symbolName: "checkmark",
            text: text,
            tone: .success,
            duration: nil,
            presentation: .result
        )
    }

    func showBusy() {
        show(
            symbolName: "ellipsis",
            text: "Working",
            tone: .busy,
            duration: 1.0,
            presentation: .compact
        )
    }

    func showError(_ message: String) {
        show(
            symbolName: "exclamationmark",
            text: message,
            tone: .warning,
            duration: 3.8,
            presentation: .compact
        )
    }

    private func show(
        symbolName: String,
        text: String?,
        tone: Tone,
        duration: TimeInterval?,
        presentation: Presentation
    ) {
        generation += 1
        let thisGeneration = generation
        stopMouseExitDismissal()
        panel?.orderOut(nil)

        let message = text ?? ""
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = ShortcutUIStyle.primaryTextColor
        label.lineBreakMode = presentation == .result ? .byWordWrapping : .byTruncatingTail
        label.maximumNumberOfLines = presentation == .result ? 8 : 1
        label.cell?.wraps = presentation == .result
        label.cell?.isScrollable = false
        label.setAccessibilityLabel(message)

        let hasText = !message.isEmpty
        let width: CGFloat
        let height: CGFloat
        let labelFrame: NSRect
        let imageFrame: NSRect
        switch presentation {
        case .compact:
            label.sizeToFit()
            width = hasText ? min(460, max(126, label.frame.width + 62)) : 48
            height = 44
            labelFrame = NSRect(x: 44, y: 13, width: width - 58, height: 18)
            imageFrame = NSRect(x: 14, y: 13, width: 18, height: 18)
        case .result:
            width = 460
            let contentWidth = width - 58
            let font = label.font ?? .systemFont(ofSize: 13, weight: .medium)
            let measuredHeight = hasText
                ? ceil(
                    (message as NSString).boundingRect(
                        with: NSSize(
                            width: contentWidth,
                            height: CGFloat.greatestFiniteMagnitude
                        ),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: [.font: font]
                    ).height
                )
                : 18
            let maxBodyHeight = NSLayoutManager().defaultLineHeight(for: font) * 8
            let bodyHeight = min(maxBodyHeight, max(18, measuredHeight))
            height = bodyHeight + 28
            labelFrame = NSRect(
                x: 44,
                y: 14,
                width: contentWidth,
                height: bodyHeight
            )
            imageFrame = NSRect(x: 14, y: height - 32, width: 18, height: 18)
        }
        let hudPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hudPanel.level = .statusBar
        hudPanel.isOpaque = false
        hudPanel.backgroundColor = .clear
        hudPanel.hasShadow = true
        hudPanel.appearance = NSAppearance(named: .darkAqua)
        hudPanel.ignoresMouseEvents = true
        hudPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSView(frame: hudPanel.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        ShortcutUIStyle.configurePanelSurface(
            background,
            cornerRadius: ShortcutUIStyle.hudCornerRadius
        )

        let imageView = NSImageView(frame: imageFrame)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        imageView.contentTintColor = tone.accentColor
        background.addSubview(imageView)

        if hasText {
            label.frame = labelFrame
            background.addSubview(label)
        }
        hudPanel.contentView = background

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: mouse.x, y: mouse.y, width: width, height: height)
        let x = min(max(mouse.x - width / 2, visible.minX + 8), visible.maxX - width - 8)
        let y = min(max(mouse.y + 24, visible.minY + 8), visible.maxY - height - 8)
        hudPanel.setFrameOrigin(NSPoint(x: x, y: y))
        hudPanel.orderFrontRegardless()
        panel = hudPanel

        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak hudPanel] in
                guard let self, self.generation == thisGeneration else {
                    return
                }
                hudPanel?.orderOut(nil)
                self.panel = nil
            }
        } else {
            beginMouseExitDismissal(
                generation: thisGeneration,
                hudPanel: hudPanel,
                initialMouseLocation: mouse
            )
        }
    }

    /// Keeps a result popup visible until the cursor moves away from it.
    private func beginMouseExitDismissal(
        generation thisGeneration: Int,
        hudPanel: NSPanel,
        initialMouseLocation: NSPoint
    ) {
        dismissOnMouseExit = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // The cursor may start inside the popup; only leaving it dismisses.
        timer.schedule(deadline: .now() + 0.3, repeating: 0.15)
        timer.setEventHandler { [weak self, weak hudPanel] in
            guard let self,
                  self.dismissOnMouseExit,
                  self.generation == thisGeneration else {
                return
            }
            let mouse = NSEvent.mouseLocation
            let panelFrame = hudPanel?.frame ?? .zero
            if CalculateResultDismissalPolicy.shouldDismiss(
                initialMouseX: initialMouseLocation.x,
                initialMouseY: initialMouseLocation.y,
                currentMouseX: mouse.x,
                currentMouseY: mouse.y,
                panelMinX: panelFrame.origin.x,
                panelMinY: panelFrame.origin.y,
                panelWidth: panelFrame.size.width,
                panelHeight: panelFrame.size.height
            ) {
                self.stopMouseExitDismissal()
                guard self.generation == thisGeneration else {
                    return
                }
                hudPanel?.orderOut(nil)
                self.panel = nil
            }
        }
        timer.resume()
        mouseExitPoller = timer
    }

    private func stopMouseExitDismissal() {
        mouseExitPoller?.cancel()
        mouseExitPoller = nil
        dismissOnMouseExit = false
    }
}
