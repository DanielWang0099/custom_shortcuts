import AIShortcutsCore
import AIShortcutsRendering
import AppKit

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw CheckFailure(description: message)
    }
}

@main
@MainActor
struct RenderingChecks {
    static func main() {
        do {
            try markdownAndClipboardCheck()
            try webTranscriptCheck()
            try mathAttachmentCheck()
            try navierStokesMathCheck()
            try fractionAndScriptLayoutCheck()
            try commonDelimiterAndPlainTextCheck()
            try displayMathLayoutCheck()
            try multilineDisplayMathCheck()
            try tableCellRichContentCheck()
            try textKitDocumentReflowCheck()
            try unsupportedMathFallbackCheck()
            print("All AI Shortcuts rendering checks passed.")
        } catch {
            print("Rendering check failed: \(error)")
            exit(EXIT_FAILURE)
        }
    }

    private static func markdownAndClipboardCheck() throws {
        let source = "# Result\n\n- **Total:** $12.00\n- [OpenAI](https://openai.com)\n\n```\n<script>literal</script>\n```"
        let rendered = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: source)
        )
        try expect(
            rendered.attributedString.string.contains("Result")
                && rendered.attributedString.string.contains("Total")
                && rendered.attributedString.string.contains("literal"),
            "Markdown content was not preserved in the native attributed output."
        )
        try expect(
            !rendered.hasMathAttachments
                && rendered.clipboardPayload.plainText == source
                && rendered.clipboardPayload.htmlData != nil
                && rendered.clipboardPayload.rtfData != nil
                && rendered.clipboardPayload.rtfdData != nil,
            "Plain Markdown output did not produce the required clipboard flavors."
        )
        let linkTextRange = rendered.attributedString.string.range(of: "OpenAI")
        if let linkTextRange {
            let linkNSRange = NSRange(linkTextRange, in: rendered.attributedString.string)
            try expect(
                rendered.attributedString.attribute(
                    .link,
                    at: linkNSRange.location,
                    effectiveRange: nil
                ) == nil,
                "Rendered links should be selectable without automatic navigation."
            )
        } else {
            throw CheckFailure(description: "Rendered Markdown lost link text.")
        }
        if let htmlData = rendered.clipboardPayload.htmlData,
           let html = String(data: htmlData, encoding: .utf8)
        {
            try expect(
                !html.localizedCaseInsensitiveContains("<script>"),
                "Clipboard HTML exposed executable markup from a code fence."
            )
        } else {
            throw CheckFailure(description: "Rendered Markdown did not produce UTF-8 HTML.")
        }

        let table = NativeRichTextRenderer().render(
            AIOutputDocument(
                format: .markdown,
                source: "| Name | Value |\n| --- | --- |\n| Count | 2 |"
            )
        )
        let headerCount = table.attributedString.string
            .components(separatedBy: "Name")
            .count - 1
        try expect(
            headerCount == 1
                && table.attributedString.string.contains("Count"),
            "Markdown tables were not rendered as a single native table."
        )
    }

    private static func webTranscriptCheck() throws {
        let source = """
        For an incompressible fluid, the **Navier–Stokes equations** are

        \\[
        \\rho\\left(\\frac{\\partial \\mathbf{u}}{\\partial t} + (\\mathbf{u}\\cdot\\nabla)\\mathbf{u}\\right)
        \\]
        """
        let renderer = WebRichTextRenderer()
        let rendered = renderer.render(
            AIOutputDocument(format: .markdown, source: source)
        )
        let page = renderer.htmlDocument(
            body: "<main class=\"transcript\"><article class=\"message-assistant\">\(rendered)</article></main>"
        )
        let userMarkup = renderer.renderPlainText("equation for navier stokes")
        let katexScriptExists = renderer.resourceBaseURL
            .map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("KaTeX/katex.min.js").path) }
            ?? false
        try expect(
            rendered.contains("class=\"math-block\"")
                && !rendered.hasPrefix("<main")
                && !rendered.contains("\\[")
                && rendered.contains("data-display=\"true\"")
                && userMarkup.contains("plain-text")
                && katexScriptExists
                && page.contains("KaTeX/katex.min.js")
                && page.contains("KaTeX/katex.min.css")
                && page.contains("--accent: #8074fb"),
            "The local WebKit transcript document was missing styled math or app theme resources."
        )

        let unsafe = renderer.render(
            AIOutputDocument(format: .markdown, source: "<script>alert(1)</script>")
        )
        try expect(
            unsafe.contains("&lt;script&gt;") && !unsafe.contains("<script>alert"),
            "Web transcript rendering did not escape unsafe source content."
        )

        let legacyEnvelope = renderer.render(
            AIOutputDocument(
                format: .plainText,
                source: "{\"format\":\"plain_text\",\"content\":\"Glad it helped!\"}"
            )
        )
        try expect(
            legacyEnvelope.contains("Glad it helped!")
                && !legacyEnvelope.contains("format")
                && !legacyEnvelope.contains("content"),
            "A structured plain-text envelope was displayed instead of its content."
        )
    }

    private static func mathAttachmentCheck() throws {
        let source = "Energy: \\(E = mc^2\\)\n\n\\[\\frac{1}{2}mv^2\\]"
        let rendered = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: source)
        )
        try expect(
            rendered.hasMathAttachments
                && rendered.clipboardPayload.plainText == source
                && rendered.clipboardPayload.htmlData != nil
                && rendered.clipboardPayload.rtfData != nil
                && rendered.clipboardPayload.rtfdData != nil,
            "Supported LaTeX was not rendered and exported with a source fallback."
        )

        let backpropagation = """
        Backpropagation computes gradients using the chain rule. For layer \\(l\\):

        - Error term: \\[\\Delta^{(l)} = \\left((W^{(l+1)})^T \\Delta^{(l+1)}\\right) \\odot f'(z^{(l)})\\]
        """
        let backpropagationRendered = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: backpropagation)
        )
        try expect(
            backpropagationRendered.hasMathAttachments
                && backpropagationRendered.fallbackMathSources.isEmpty,
            "The backpropagation equation was incorrectly left as raw LaTeX."
        )
    }

    private static func fractionAndScriptLayoutCheck() throws {
        let source = #"\[\frac{\partial J}{\partial W} = \delta^l (a^{l-1})^T\]"#
        let rendered = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: source)
        )
        guard let attachment = firstAttachment(in: rendered.attributedString),
              let image = attachment.image,
              let fractionOpaqueBounds = opaqueBounds(of: image)
        else {
            throw CheckFailure(description: "The fraction regression fixture did not produce an image attachment.")
        }
        let imageHeight = image.size.height
        try expect(
            fractionOpaqueBounds.minY < imageHeight * 0.30
                && fractionOpaqueBounds.maxY > imageHeight * 0.70,
            "Fraction math clipped the numerator or denominator inside its bitmap."
        )
        try expect(
            rendered.fallbackMathSources.isEmpty,
            "The fraction and script regression fixture unexpectedly fell back to source."
        )

        let nestedSource = #"\[\frac{\frac{1}{x^2}}{\sqrt{y_i}} + z^{n+1}_{k}\]"#
        let nestedRendered = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: nestedSource)
        )
        guard let nestedAttachment = firstAttachment(in: nestedRendered.attributedString),
              let nestedImage = nestedAttachment.image,
              let nestedOpaqueBounds = opaqueBounds(of: nestedImage)
        else {
            throw CheckFailure(description: "The nested fraction regression fixture did not produce an image attachment.")
        }
        let nestedImageHeight = nestedImage.size.height
        try expect(
            nestedOpaqueBounds.minY < nestedImageHeight * 0.25
                && nestedOpaqueBounds.maxY > nestedImageHeight * 0.75
                && nestedRendered.fallbackMathSources.isEmpty,
            "Nested fractions or scripts were clipped or fell back to source."
        )
    }

    private static func navierStokesMathCheck() throws {
        let source = """
        For an incompressible fluid, the **Navier–Stokes equations** are

        \\[
        \\rho\\left(\\frac{\\partial \\mathbf{u}}{\\partial t} + (\\mathbf{u}\\cdot\\nabla)\\mathbf{u}\\right)
        \\]
        """
        let rendered = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: source)
        )
        let equationWidth = firstAttachment(in: rendered.attributedString)?.image?.size.width
        try expect(
            attachmentCount(in: rendered.attributedString) == 1
                && rendered.fallbackMathSources.isEmpty
                && !rendered.attributedString.string.contains("\\mathbf")
                && !rendered.attributedString.string.contains("\\[")
                && (equationWidth ?? .greatestFiniteMagnitude) < 540,
            "The Navier–Stokes equation fell back to visible LaTeX source."
        )
    }

    private static func commonDelimiterAndPlainTextCheck() throws {
        let delimiterSource = #"\[\left[\langle x \rangle\right] + \Vert y \Vert\]"#
        let rendered = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: delimiterSource)
        )
        try expect(
            attachmentCount(in: rendered.attributedString) == 1
                && rendered.fallbackMathSources.isEmpty,
            "Common left/right delimiter forms were not rendered as native math."
        )

        let literalSource = #"Literal \(x^2\)"#
        let literal = NativeRichTextRenderer().render(
            AIOutputDocument(format: .plainText, source: literalSource)
        )
        try expect(
            attachmentCount(in: literal.attributedString) == 0
                && literal.attributedString.string == literalSource,
            "Plain-text output was heuristically converted into rendered math."
        )
    }

    private static func displayMathLayoutCheck() throws {
        let source = "Before \\[x^2\\] After"
        let rendered = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: source)
        )
        guard let attachmentRange = firstAttachmentRange(in: rendered.attributedString) else {
            throw CheckFailure(description: "Display math did not produce an attachment.")
        }
        let paragraphStyle = rendered.attributedString.attribute(
            .paragraphStyle,
            at: attachmentRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let value = rendered.attributedString.string
        let before = String(value[..<value.index(value.startIndex, offsetBy: attachmentRange.location)])
        let afterStart = value.index(value.startIndex, offsetBy: attachmentRange.upperBound)
        let after = String(value[afterStart...])
        try expect(
            paragraphStyle?.alignment == .center,
            "Display math was not assigned a centered paragraph style."
        )
        try expect(
            before.hasSuffix("\n") && after.hasPrefix("\n"),
            "Display math remained embedded in surrounding paragraph text."
        )
    }

    private static func multilineDisplayMathCheck() throws {
        let source = "Canonical:\n\\[\n\\frac{1}{2}\n\\]\n\nDollar:\n$$\n\\sqrt{x}\n$$"
        let rendered = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: source)
        )
        try expect(
            attachmentCount(in: rendered.attributedString) == 2
                && rendered.fallbackMathSources.isEmpty,
            "Multiline display math was not parsed and rendered without fallback."
        )
    }

    private static func tableCellRichContentCheck() throws {
        let source = "| Name | Formula |\n| --- | --- |\n| Energy | \\(E=mc^2\\) |"
        let rendered = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: source)
        )
        try expect(
            attachmentCount(in: rendered.attributedString) == 1
                && rendered.fallbackMathSources.isEmpty,
            "Inline math inside a Markdown table cell bypassed the rich renderer."
        )
    }

    private static func textKitDocumentReflowCheck() throws {
        let source = "# Answer\n\nIntroductory text.\n\n\\[\\frac{\\partial J}{\\partial W}\\]\n\nMore text after the equation."
        let rendered = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: source)
        )
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 80)
        )
        textView.isRichText = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(rendered.attributedString)

        let measuredHeight = NativeTextViewLayout.fitDocumentView(
            textView,
            minimumHeight: 80
        )
        try expect(
            measuredHeight > 80 && textView.frame.height > 80,
            "Rich TextKit content did not expand the document view for scrolling."
        )
        try expect(
            textView.layoutManager?.glyphRange(for: textView.textContainer!).length
                == rendered.attributedString.length,
            "TextKit reflow did not lay out the complete rich document."
        )
    }

    private static func firstAttachment(in attributedString: NSAttributedString) -> NSTextAttachment? {
        var result: NSTextAttachment?
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, stop in
            if let attachment = value as? NSTextAttachment {
                result = attachment
                stop.pointee = true
            }
        }
        return result
    }

    private static func firstAttachmentRange(in attributedString: NSAttributedString) -> NSRange? {
        var result: NSRange?
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, stop in
            if value is NSTextAttachment {
                result = range
                stop.pointee = true
            }
        }
        return result
    }

    private static func attachmentCount(in attributedString: NSAttributedString) -> Int {
        var count = 0
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, _ in
            if value is NSTextAttachment {
                count += 1
            }
        }
        return count
    }

    private static func opaqueBounds(of image: NSImage) -> NSRect? {
        guard let representation = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .first
        else {
            return nil
        }
        var minX = representation.pixelsWide
        var minY = representation.pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide {
                guard representation.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.01 else {
                    continue
                }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            return nil
        }
        return NSRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    private static func unsupportedMathFallbackCheck() throws {
        let source = "Matrix: \\[\\begin{matrix}a & b\\end{matrix}\\]"
        let rendered = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: source)
        )
        try expect(
            rendered.fallbackMathSources == ["\\[\\begin{matrix}a & b\\end{matrix}\\]"]
                && rendered.attributedString.string.contains("begin{matrix}"),
            "Unsupported LaTeX was not kept visible as selectable source."
        )

        let unsafe = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: "<script>alert(1)</script>")
        )
        try expect(
            unsafe.attributedString.string == "<script>alert(1)</script>"
                && unsafe.fallbackMathSources.isEmpty,
            "Unsafe Markdown was not preserved as escaped plain source."
        )
        if let htmlData = unsafe.clipboardPayload.htmlData,
           let html = String(data: htmlData, encoding: .utf8)
        {
            try expect(
                !html.localizedCaseInsensitiveContains("<script>"),
                "Unsafe Markdown leaked executable markup into clipboard HTML."
            )
        } else {
            throw CheckFailure(description: "Unsafe Markdown did not produce fallback HTML.")
        }

        let malformed = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: "Broken equation: \\(x^2")
        )
        let malformedSourceRange = malformed.attributedString.string.range(of: "\\")
        let malformedSourceLocation = malformedSourceRange.map {
            NSRange($0, in: malformed.attributedString.string).location
        } ?? 0
        try expect(
            malformed.attributedString.string == "Broken equation: \\(x^2"
                && malformed.attributedString.attribute(
                    .backgroundColor,
                    at: malformedSourceLocation,
                    effectiveRange: nil
                ) != nil,
            "Malformed LaTeX was not kept as visibly styled source."
        )

        let malformedDollar = NativeRichTextRenderer().render(
            AIOutputDocument(format: .markdown, source: "Broken dollar math: $x^2")
        )
        try expect(
            malformedDollar.attributedString.string == "Broken dollar math: $x^2"
                && malformedDollar.attributedString.attribute(
                    .backgroundColor,
                    at: malformedDollar.attributedString.length - 1,
                    effectiveRange: nil
                ) != nil,
            "Malformed dollar math was not kept as visibly styled source."
        )
    }
}
