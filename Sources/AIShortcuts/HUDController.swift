import AppKit

@MainActor
final class HUDController {
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

    func showSuccess(text: String? = nil) {
        show(symbolName: "checkmark", text: text, tone: .success, duration: 0.9)
    }

    func showBusy() {
        show(symbolName: "ellipsis", text: "Working", tone: .busy, duration: 1.0)
    }

    func showError(_ message: String) {
        show(
            symbolName: "exclamationmark",
            text: message,
            tone: .warning,
            duration: 3.8
        )
    }

    private func show(
        symbolName: String,
        text: String?,
        tone: Tone,
        duration: TimeInterval
    ) {
        generation += 1
        let thisGeneration = generation
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text ?? "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = ShortcutUIStyle.primaryTextColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityLabel(text)
        label.sizeToFit()

        let hasText = !(text ?? "").isEmpty
        let width = hasText ? min(460, max(126, label.frame.width + 62)) : 48
        let height: CGFloat = 44
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

        let imageView = NSImageView(frame: NSRect(x: 14, y: 13, width: 18, height: 18))
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        imageView.contentTintColor = tone.accentColor
        background.addSubview(imageView)

        if hasText {
            label.frame = NSRect(x: 44, y: 13, width: width - 58, height: 18)
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

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak hudPanel] in
            guard let self, self.generation == thisGeneration else {
                return
            }
            hudPanel?.orderOut(nil)
            self.panel = nil
        }
    }
}
