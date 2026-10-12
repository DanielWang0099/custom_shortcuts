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
        let bounds = CGRect(x: 272, y: 262, width: 713, height: 742)
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

    // Vector version of the chosen mark in Resources/AIShortcutsLogo.png. Keep
    // these paths aligned with AIShortcutsLogo.svg. Both icon sizes use this mark.
    private static func drawMark(in context: CGContext, color: CGColor) {
        let bolt = CGMutablePath()
        bolt.move(to: CGPoint(x: 634, y: 345))
        bolt.addLine(to: CGPoint(x: 977, y: 264))
        bolt.addQuadCurve(to: CGPoint(x: 982, y: 271), control: CGPoint(x: 985, y: 262))
        bolt.addLine(to: CGPoint(x: 870, y: 557))
        bolt.addQuadCurve(to: CGPoint(x: 865, y: 557), control: CGPoint(x: 868, y: 563))
        bolt.addLine(to: CGPoint(x: 830, y: 490))
        bolt.addQuadCurve(to: CGPoint(x: 821, y: 489), control: CGPoint(x: 826, y: 483))
        bolt.addLine(to: CGPoint(x: 713, y: 616))
        bolt.addQuadCurve(to: CGPoint(x: 716, y: 622), control: CGPoint(x: 709, y: 622))
        bolt.addLine(to: CGPoint(x: 866, y: 622))
        bolt.addQuadCurve(to: CGPoint(x: 870, y: 631), control: CGPoint(x: 875, y: 622))
        bolt.addLine(to: CGPoint(x: 464, y: 1000))
        bolt.addQuadCurve(to: CGPoint(x: 457, y: 997), control: CGPoint(x: 457, y: 1006))
        bolt.addLine(to: CGPoint(x: 624, y: 721))
        bolt.addQuadCurve(to: CGPoint(x: 620, y: 716), control: CGPoint(x: 627, y: 715))
        bolt.addLine(to: CGPoint(x: 437, y: 733))
        bolt.addQuadCurve(to: CGPoint(x: 431, y: 723), control: CGPoint(x: 425, y: 734))
        bolt.addLine(to: CGPoint(x: 739, y: 409))
        bolt.addQuadCurve(to: CGPoint(x: 736, y: 399), control: CGPoint(x: 743, y: 403))
        bolt.addLine(to: CGPoint(x: 633, y: 351))
        bolt.addQuadCurve(to: CGPoint(x: 634, y: 345), control: CGPoint(x: 624, y: 347))
        bolt.closeSubpath()

        let upperTrail = CGMutablePath()
        upperTrail.move(to: CGPoint(x: 382, y: 435))
        upperTrail.addLine(to: CGPoint(x: 642, y: 396))
        upperTrail.addQuadCurve(to: CGPoint(x: 668, y: 404), control: CGPoint(x: 659, y: 392))
        upperTrail.addQuadCurve(to: CGPoint(x: 667, y: 418), control: CGPoint(x: 673, y: 411))
        upperTrail.addLine(to: CGPoint(x: 655, y: 431))
        upperTrail.addLine(to: CGPoint(x: 390, y: 478))
        upperTrail.addQuadCurve(to: CGPoint(x: 365, y: 466), control: CGPoint(x: 369, y: 483))
        upperTrail.addQuadCurve(to: CGPoint(x: 382, y: 435), control: CGPoint(x: 359, y: 447))
        upperTrail.closeSubpath()

        let lowerTrail = CGMutablePath()
        lowerTrail.move(to: CGPoint(x: 293, y: 525))
        lowerTrail.addLine(to: CGPoint(x: 570, y: 474))
        lowerTrail.addQuadCurve(to: CGPoint(x: 592, y: 481), control: CGPoint(x: 585, y: 471))
        lowerTrail.addQuadCurve(to: CGPoint(x: 592, y: 497), control: CGPoint(x: 599, y: 488))
        lowerTrail.addLine(to: CGPoint(x: 581, y: 510))
        lowerTrail.addLine(to: CGPoint(x: 303, y: 561))
        lowerTrail.addQuadCurve(to: CGPoint(x: 275, y: 550), control: CGPoint(x: 281, y: 567))
        lowerTrail.addQuadCurve(to: CGPoint(x: 293, y: 525), control: CGPoint(x: 267, y: 533))
        lowerTrail.closeSubpath()

        context.setFillColor(color)
        for path in [bolt, upperTrail, lowerTrail] {
            context.addPath(path)
            context.fillPath()
        }
    }
}
