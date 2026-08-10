import AppKit

@MainActor
final class ClipboardQueueIndicatorController {
    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 376, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = ClipboardQueueSurfaceView(frame: panel.contentView?.bounds ?? .zero)

        icon.frame = NSRect(x: 17, y: 17, width: 24, height: 24)
        icon.contentTintColor = ShortcutUIStyle.accentColor
        background.addSubview(icon)

        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.textColor = ShortcutUIStyle.primaryTextColor
        title.frame = NSRect(x: 52, y: 30, width: 305, height: 18)
        background.addSubview(title)

        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = ShortcutUIStyle.secondaryTextColor
        detail.frame = NSRect(x: 52, y: 11, width: 305, height: 16)
        background.addSubview(detail)
        panel.contentView = background
    }

    func show(mode: ClipboardQueueMode, count: Int) {
        switch mode {
        case .inactive:
            dismiss()
            return
        case .collecting:
            title.stringValue = "Sequential Clipboard · collecting"
            detail.stringValue = "\(count) queued · ⌘C adds · ⌃⌥⌘C starts pasting"
            icon.image = NSImage(
                systemSymbolName: "square.stack.3d.up",
                accessibilityDescription: "Collecting clipboard items"
            )
        case .pasting:
            title.stringValue = "Sequential Clipboard · pasting"
            detail.stringValue = "\(count) remaining · ⌘V pastes next · ⌃⌥⌘C cancels"
            icon.image = NSImage(
                systemSymbolName: "arrow.down.to.line.compact",
                accessibilityDescription: "Pasting clipboard queue"
            )
        }

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

private final class ClipboardQueueSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ShortcutUIStyle.configurePanelSurface(
            self,
            cornerRadius: ShortcutUIStyle.hudCornerRadius
        )
    }

    required init?(coder: NSCoder) {
        nil
    }
}
