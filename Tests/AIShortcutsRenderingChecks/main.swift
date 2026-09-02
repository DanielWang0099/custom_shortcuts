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
            try mathAttachmentCheck()
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
