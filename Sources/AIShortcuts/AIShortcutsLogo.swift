import AppKit
import CoreGraphics

@MainActor
enum AIShortcutsLogo {
    private static let graphite = NSColor(
        srgbRed: 0.105,
        green: 0.110,
        blue: 0.125,
        alpha: 1
    )
    private static let purple = NSColor(
        srgbRed: 0.500,
        green: 0.455,
        blue: 0.985,
        alpha: 1
    )
    private static let lilac = NSColor(
        srgbRed: 0.690,
        green: 0.655,
        blue: 1.000,
        alpha: 1
    )

    static func menuBarImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else {
            return image
        }

        context.saveGState()
        drawMark(
            in: context,
            size: size,
            primary: NSColor.white.cgColor,
            secondary: NSColor.white.cgColor
        )
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
        let tilePath = CGPath(
            roundedRect: tile,
            cornerWidth: size * 0.22,
            cornerHeight: size * 0.22,
            transform: nil
        )

        context.addPath(tilePath)
        context.setFillColor(graphite.cgColor)
        context.fillPath()

        context.addPath(tilePath)
        context.setStrokeColor(purple.withAlphaComponent(0.48).cgColor)
        context.setLineWidth(size * 0.012)
        context.strokePath()

        drawMark(
            in: context,
            size: size,
            primary: purple.cgColor,
            secondary: lilac.cgColor
        )
        context.restoreGState()

        image.accessibilityDescription = "AI Shortcuts"
        return image
    }

    private static func drawMark(
        in context: CGContext,
        size: CGFloat,
        primary: CGColor,
        secondary: CGColor
    ) {
        let upper = CGMutablePath()
        upper.move(to: CGPoint(x: size * 0.22, y: size * 0.58))
        upper.addCurve(
            to: CGPoint(x: size * 0.55, y: size * 0.68),
            control1: CGPoint(x: size * 0.32, y: size * 0.80),
            control2: CGPoint(x: size * 0.45, y: size * 0.80)
        )
        upper.addCurve(
            to: CGPoint(x: size * 0.78, y: size * 0.42),
            control1: CGPoint(x: size * 0.66, y: size * 0.58),
            control2: CGPoint(x: size * 0.70, y: size * 0.42)
        )

        let lower = CGMutablePath()
        lower.move(to: CGPoint(x: size * 0.22, y: size * 0.42))
        lower.addCurve(
            to: CGPoint(x: size * 0.55, y: size * 0.32),
            control1: CGPoint(x: size * 0.32, y: size * 0.20),
            control2: CGPoint(x: size * 0.45, y: size * 0.20)
        )
        lower.addCurve(
            to: CGPoint(x: size * 0.78, y: size * 0.58),
            control1: CGPoint(x: size * 0.66, y: size * 0.42),
            control2: CGPoint(x: size * 0.70, y: size * 0.58)
        )

        context.setLineWidth(max(size * 0.085, 1.5))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.addPath(upper)
        context.setStrokeColor(primary)
        context.strokePath()

        context.addPath(lower)
        context.setStrokeColor(secondary)
        context.strokePath()

        let center = CGPoint(x: size * 0.78, y: size * 0.78)
        let outerRadius = size * 0.095
        let innerRadius = size * 0.026
        let spark = CGMutablePath()
        spark.move(to: CGPoint(x: center.x, y: center.y + outerRadius))
        spark.addLine(to: CGPoint(x: center.x + innerRadius, y: center.y + innerRadius))
        spark.addLine(to: CGPoint(x: center.x + outerRadius, y: center.y))
        spark.addLine(to: CGPoint(x: center.x + innerRadius, y: center.y - innerRadius))
        spark.addLine(to: CGPoint(x: center.x, y: center.y - outerRadius))
        spark.addLine(to: CGPoint(x: center.x - innerRadius, y: center.y - innerRadius))
        spark.addLine(to: CGPoint(x: center.x - outerRadius, y: center.y))
        spark.addLine(to: CGPoint(x: center.x - innerRadius, y: center.y + innerRadius))
        spark.closeSubpath()

        context.addPath(spark)
        context.setFillColor(secondary)
        context.fillPath()
    }
}
