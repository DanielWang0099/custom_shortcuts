import AppKit
import AIShortcutsCore

@MainActor
enum ShortcutUIStyle {
    static let promptCornerRadius: CGFloat = 22
    static let hudCornerRadius: CGFloat = 14
    static let explainCornerRadius: CGFloat = 24
    static let inputCornerRadius: CGFloat = 16

    // The shortcut UI intentionally uses one stable graphite palette. These
    // panels float over arbitrary apps, so inheriting the host appearance can
    // turn them into a bright white sheet over otherwise dark content.
    static let shellColor = NSColor(
        srgbRed: 0.105,
        green: 0.110,
        blue: 0.125,
        alpha: 0.985
    )
    static let raisedSurfaceColor = NSColor(
        srgbRed: 0.155,
        green: 0.160,
        blue: 0.180,
        alpha: 1
    )
    static let primaryTextColor = NSColor(
        srgbRed: 0.965,
        green: 0.968,
        blue: 0.980,
        alpha: 1
    )
    static let secondaryTextColor = NSColor(
        srgbRed: 0.670,
        green: 0.685,
        blue: 0.735,
        alpha: 1
    )
    static let placeholderTextColor = NSColor(
        srgbRed: 0.470,
        green: 0.485,
        blue: 0.535,
        alpha: 1
    )
    static let accentColor = NSColor(
        srgbRed: 0.500,
        green: 0.455,
        blue: 0.985,
        alpha: 1
    )
    static let successAccentColor = NSColor(
        srgbRed: 0.610,
        green: 0.760,
        blue: 0.675,
        alpha: 1
    )
    static let warningAccentColor = NSColor(
        srgbRed: 0.855,
        green: 0.610,
        blue: 0.430,
        alpha: 1
    )
    static let userBubbleColor = NSColor(
        srgbRed: 0.155,
        green: 0.150,
        blue: 0.205,
        alpha: 1
    )
    static let userBubbleBorderColor = accentColor.withAlphaComponent(0.34)
    static let panelBorderColor = NSColor.white.withAlphaComponent(0.12)
    static let contentBorderColor = NSColor.white.withAlphaComponent(0.10)
    static let focusBorderColor = accentColor.withAlphaComponent(0.72)

    static func configurePanelSurface(
        _ view: NSView,
        cornerRadius: CGFloat
    ) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = shellColor.cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = panelBorderColor.cgColor
    }

    static func configureMaterialSurface(
        _ view: NSVisualEffectView,
        cornerRadius: CGFloat
    ) {
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.borderWidth = 1
        view.layer?.borderColor = panelBorderColor.cgColor
    }

    static func configureContentSurface(
        _ view: NSView,
        cornerRadius: CGFloat
    ) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.backgroundColor = raisedSurfaceColor.cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = contentBorderColor.cgColor
    }

    static func shortcutLabel(for definition: HotKeyDefinition) -> String {
        let key: String
        switch definition.virtualKeyCode {
        case 21: key = "4"
        case 15: key = "R"
        case 17: key = "T"
        case 3: key = "F"
        case 42: key = "\\"
        case 14: key = "E"
        case 24: key = "="
        case 37: key = "L"
        case 8: key = "C"
        case 34: key = "I"
        default: key = "?"
        }
        return "⌃⌥⌘\(key)"
    }
}
