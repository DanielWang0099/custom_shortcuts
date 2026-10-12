import AppKit
import CoreGraphics

@MainActor
enum AIShortcutsLogo {
    private static let graphite = NSColor(
        srgbRed: 27 / 255,
        green: 28 / 255,
        blue: 32 / 255,
        alpha: 1
    )
    private static let purple = NSColor(
        srgbRed: 128 / 255,
        green: 116 / 255,
        blue: 251 / 255,
        alpha: 1
    )

    static func menuBarImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else {
            return image
        }

        // Fit the mark itself, without the app tile's padding, at menu-bar size.
        let bounds = CGRect(x: 238, y: 282, width: 787, height: 722)
        let scale = max(1, size - 2) / max(bounds.width, bounds.height)
        context.saveGState()
        context.translateBy(
            x: (size - bounds.width * scale) / 2,
            y: (size + bounds.height * scale) / 2
        )
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        drawMark(in: context, color: NSColor.white.cgColor)
        context.restoreGState()

        image.isTemplate = true
        image.accessibilityDescription = "AI Shortcuts"
        return image
    }

    static func appIconImage(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else {
            return image
        }

        context.saveGState()
        let canvas = CGRect(x: 0, y: 0, width: size, height: size)
        let tile = canvas.insetBy(dx: size * 0.04, dy: size * 0.04)
        context.addPath(CGPath(
            roundedRect: tile,
            cornerWidth: size * 0.22,
            cornerHeight: size * 0.22,
            transform: nil
        ))
        context.setFillColor(graphite.cgColor)
        context.fillPath()

        context.translateBy(x: 0, y: size)
        context.scaleBy(x: size / 1254, y: -size / 1254)
        drawMark(in: context, color: purple.cgColor)
        context.restoreGState()

        image.accessibilityDescription = "AI Shortcuts"
        return image
    }

    // Flow: a curved lightning arrow and two tapered speed trails. Keep the
    // paths aligned with the SVG; menu-bar and app icons share this geometry.
    private static func drawMark(in context: CGContext, color: CGColor) {
        let bolt = CGMutablePath()
        bolt.move(to: CGPoint(x: 755, y: 284))
        bolt.addLine(to: CGPoint(x: 1022, y: 310))
        bolt.addQuadCurve(to: CGPoint(x: 1023, y: 315), control: CGPoint(x: 1027, y: 310))
        bolt.addLine(to: CGPoint(x: 876, y: 524))
        bolt.addQuadCurve(to: CGPoint(x: 871, y: 524), control: CGPoint(x: 871, y: 533))
        bolt.addLine(to: CGPoint(x: 871, y: 434))
        bolt.addCurve(to: CGPoint(x: 724, y: 579), control1: CGPoint(x: 816, y: 482), control2: CGPoint(x: 775, y: 526))
        bolt.addCurve(to: CGPoint(x: 735, y: 604), control1: CGPoint(x: 710, y: 594), control2: CGPoint(x: 714, y: 604))
        bolt.addLine(to: CGPoint(x: 849, y: 604))
        bolt.addCurve(to: CGPoint(x: 857, y: 633), control1: CGPoint(x: 870, y: 602), control2: CGPoint(x: 873, y: 617))
        bolt.addCurve(to: CGPoint(x: 384, y: 999), control1: CGPoint(x: 733, y: 771), control2: CGPoint(x: 469, y: 950))
        bolt.addQuadCurve(to: CGPoint(x: 379, y: 992), control: CGPoint(x: 373, y: 1005))
        bolt.addLine(to: CGPoint(x: 597, y: 725))
        bolt.addCurve(to: CGPoint(x: 588, y: 697), control1: CGPoint(x: 613, y: 708), control2: CGPoint(x: 617, y: 695))
        bolt.addLine(to: CGPoint(x: 467, y: 699))
        bolt.addCurve(to: CGPoint(x: 455, y: 662), control1: CGPoint(x: 442, y: 701), control2: CGPoint(x: 442, y: 681))
        bolt.addCurve(to: CGPoint(x: 829, y: 365), control1: CGPoint(x: 524, y: 547), control2: CGPoint(x: 679, y: 448))
        bolt.addLine(to: CGPoint(x: 755, y: 288))
        bolt.addQuadCurve(to: CGPoint(x: 755, y: 284), control: CGPoint(x: 751, y: 282))
        bolt.closeSubpath()

        let upperTrail = CGMutablePath()
        upperTrail.move(to: CGPoint(x: 302, y: 513))
        upperTrail.addCurve(to: CGPoint(x: 742, y: 331), control1: CGPoint(x: 435, y: 444), control2: CGPoint(x: 625, y: 337))
        upperTrail.addCurve(to: CGPoint(x: 747, y: 370), control1: CGPoint(x: 774, y: 327), control2: CGPoint(x: 779, y: 358))
        upperTrail.addCurve(to: CGPoint(x: 302, y: 513), control1: CGPoint(x: 620, y: 390), control2: CGPoint(x: 474, y: 449))
        upperTrail.closeSubpath()

        let lowerTrail = CGMutablePath()
        lowerTrail.move(to: CGPoint(x: 238, y: 599))
        lowerTrail.addCurve(to: CGPoint(x: 603, y: 435), control1: CGPoint(x: 353, y: 533), control2: CGPoint(x: 534, y: 441))
        lowerTrail.addCurve(to: CGPoint(x: 614, y: 466), control1: CGPoint(x: 631, y: 429), control2: CGPoint(x: 639, y: 454))
        lowerTrail.addCurve(to: CGPoint(x: 238, y: 599), control1: CGPoint(x: 480, y: 509), control2: CGPoint(x: 364, y: 551))
        lowerTrail.closeSubpath()

        context.setFillColor(color)
        for path in [bolt, upperTrail, lowerTrail] {
            context.addPath(path)
            context.fillPath()
        }
    }
}
