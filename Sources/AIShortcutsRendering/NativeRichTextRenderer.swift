import AIShortcutsCore
import AppKit
import CoreGraphics

public struct RichClipboardPayload: Sendable {
    public let plainText: String
    public let htmlData: Data?
    public let rtfData: Data?
    public let rtfdData: Data?

    public init(
        plainText: String,
        htmlData: Data?,
        rtfData: Data?,
        rtfdData: Data?
    ) {
        self.plainText = plainText
        self.htmlData = htmlData
        self.rtfData = rtfData
        self.rtfdData = rtfdData
    }

    @MainActor
    public func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(plainText, forType: .string)
        if let htmlData {
            item.setData(htmlData, forType: .html)
        }
        if let rtfData {
            item.setData(rtfData, forType: .rtf)
        }
        if let rtfdData {
            item.setData(rtfdData, forType: .rtfd)
        }
        pasteboard.writeObjects([item])
    }
}

@MainActor
public struct RichTextTheme {
    public let bodyFont: NSFont
    public let codeFont: NSFont
    public let bodyColor: NSColor
    public let secondaryColor: NSColor
    public let accentColor: NSColor
    public let codeBackgroundColor: NSColor
    public let tableBorderColor: NSColor

    public init(
        bodyFont: NSFont = .systemFont(ofSize: 15),
        codeFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        bodyColor: NSColor = .labelColor,
        secondaryColor: NSColor = .secondaryLabelColor,
        accentColor: NSColor = .controlAccentColor,
        codeBackgroundColor: NSColor = NSColor.black.withAlphaComponent(0.12),
        tableBorderColor: NSColor = NSColor.separatorColor.withAlphaComponent(0.45)
    ) {
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.bodyColor = bodyColor
        self.secondaryColor = secondaryColor
        self.accentColor = accentColor
        self.codeBackgroundColor = codeBackgroundColor
        self.tableBorderColor = tableBorderColor
    }
}

@MainActor
public struct RenderedRichText {
    public let attributedString: NSAttributedString
    public let clipboardPayload: RichClipboardPayload
    public let hasMathAttachments: Bool
    public let fallbackMathSources: [String]

    public init(
        attributedString: NSAttributedString,
        clipboardPayload: RichClipboardPayload,
        hasMathAttachments: Bool,
        fallbackMathSources: [String]
    ) {
        self.attributedString = attributedString
        self.clipboardPayload = clipboardPayload
        self.hasMathAttachments = hasMathAttachments
        self.fallbackMathSources = fallbackMathSources
    }
}

@MainActor
public final class NativeRichTextRenderer {
    private let theme: RichTextTheme

    public init(theme: RichTextTheme = RichTextTheme()) {
        self.theme = theme
    }

    public func render(_ document: AIOutputDocument) -> RenderedRichText {
        let builder = RichTextBuilder(theme: theme)
        builder.render(document)
        let attributedString = builder.attributedString
        let payload = Self.makeClipboardPayload(
            source: document.source,
            attributedString: attributedString
        )
        return RenderedRichText(
            attributedString: attributedString,
            clipboardPayload: payload,
            hasMathAttachments: builder.hasMathAttachments,
            fallbackMathSources: builder.fallbackMathSources
        )
    }

    private static func makeClipboardPayload(
        source: String,
        attributedString: NSAttributedString
    ) -> RichClipboardPayload {
        let range = NSRange(location: 0, length: attributedString.length)
        let htmlData = try? attributedString.data(
            from: range,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
        )
        let rtfData = try? attributedString.data(
            from: range,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf,
            ]
        )
        let rtfdData = try? attributedString.data(
            from: range,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtfd,
            ]
        )
        return RichClipboardPayload(
            plainText: source,
            htmlData: htmlData ?? fallbackHTMLData(for: source),
            rtfData: rtfData ?? fallbackRTFData(for: source),
            rtfdData: rtfdData
        )
    }

    private static func fallbackHTMLData(for source: String) -> Data {
        let escaped = source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>\n")
        return Data("<div>\(escaped)</div>".utf8)
    }

    private static func fallbackRTFData(for source: String) -> Data? {
        try? NSAttributedString(string: source).data(
            from: NSRange(location: 0, length: source.utf16.count),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
}

@MainActor
private final class RichTextBuilder {
    private let theme: RichTextTheme
    private(set) var attributedString = NSMutableAttributedString()
    private(set) var hasMathAttachments = false
    private(set) var fallbackMathSources: [String] = []

    init(theme: RichTextTheme) {
        self.theme = theme
    }

    func render(_ document: AIOutputDocument) {
        guard (try? AIOutputDocumentValidator.validate(document)) != nil else {
            appendPlain(document.source)
            return
        }
        if document.format == .markdown {
            renderMarkdown(document.source)
        } else {
            appendPlain(document.source)
        }
        while attributedString.string.hasSuffix("\n") {
            attributedString.deleteCharacters(
                in: NSRange(location: attributedString.length - 1, length: 1)
            )
        }
    }

    private func renderMarkdown(_ source: String) {
        let lines = source.components(separatedBy: "\n")
        var index = 0
        var needsBlockBreak = false

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                needsBlockBreak = true
                index += 1
                continue
            }
            if needsBlockBreak, !attributedString.string.isEmpty {
                appendBlockBreak()
            }
            needsBlockBreak = false

            if isFenceStart(line) {
                index = renderCodeBlock(lines, startingAt: index)
                needsBlockBreak = true
                continue
            }
            if isTableStart(at: index, in: lines) {
                index = renderTable(lines, startingAt: index)
                needsBlockBreak = true
                continue
            }
            if let heading = headingContent(in: line) {
                appendHeading(heading.text, level: heading.level)
                index += 1
                needsBlockBreak = true
                continue
            }
            if listParts(in: line) != nil {
                index = renderList(lines, startingAt: index)
                needsBlockBreak = true
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                index = renderQuote(lines, startingAt: index)
                needsBlockBreak = true
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  !isFenceStart(lines[index]),
                  !isTableStart(at: index, in: lines),
                  headingContent(in: lines[index]) == nil,
                  listParts(in: lines[index]) == nil,
                  !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">")
            {
                paragraphLines.append(lines[index])
                index += 1
            }
            appendParagraph(
                paragraphLines.joined(separator: "\n"),
                style: InlineStyle(font: theme.bodyFont, color: theme.bodyColor)
            )
            needsBlockBreak = true
        }
    }

    private func appendPlain(_ text: String) {
        attributedString.append(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: theme.bodyFont,
                    .foregroundColor: theme.bodyColor,
                ]
            )
        )
    }

    private func appendHeading(_ text: String, level: Int) {
        let size = max(15, theme.bodyFont.pointSize + CGFloat(8 - level))
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = level <= 2 ? 10 : 7
        paragraph.lineSpacing = 2
        appendInline(
            text,
            style: InlineStyle(font: font, color: theme.bodyColor, bold: true)
        )
        appendNewline(with: paragraph)
    }

    private func appendParagraph(_ text: String, style: InlineStyle) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 8
        paragraph.lineSpacing = 3
        appendInline(text, style: style)
        appendNewline(with: paragraph)
    }

    private func appendBlockBreak() {
        attributedString.append(
            NSAttributedString(
                string: "\n",
                attributes: [
                    .font: theme.bodyFont,
                    .foregroundColor: theme.bodyColor,
                ]
            )
        )
    }

    private func appendNewline(with paragraph: NSParagraphStyle) {
        attributedString.append(
            NSAttributedString(
                string: "\n",
                attributes: [
                    .font: theme.bodyFont,
                    .foregroundColor: theme.bodyColor,
                    .paragraphStyle: paragraph,
                ]
            )
        )
    }

    private func renderCodeBlock(
        _ lines: [String],
        startingAt start: Int
    ) -> Int {
        var index = start + 1
        var codeLines: [String] = []
        while index < lines.count, !isFenceStart(lines[index]) {
            codeLines.append(lines[index])
            index += 1
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 8
        paragraph.firstLineHeadIndent = 10
        paragraph.headIndent = 10
        paragraph.tailIndent = -10
        let attributes: [NSAttributedString.Key: Any] = [
            .font: theme.codeFont,
            .foregroundColor: theme.bodyColor,
            .backgroundColor: theme.codeBackgroundColor,
            .paragraphStyle: paragraph,
        ]
        attributedString.append(
            NSAttributedString(
                string: codeLines.joined(separator: "\n") + "\n",
                attributes: attributes
            )
        )
        return min(lines.count, index + 1)
    }

    private func renderList(
        _ lines: [String],
        startingAt start: Int
    ) -> Int {
        var index = start
        var orderedIndex = 1
        while index < lines.count, let parts = listParts(in: lines[index]) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = 24
            paragraph.firstLineHeadIndent = 4
            paragraph.paragraphSpacing = 4
            paragraph.lineSpacing = 2
            let marker = parts.marker.last == "."
                ? "\(orderedIndex). "
                : "• "
            attributedString.append(
                NSAttributedString(
                    string: marker,
                    attributes: [
                        .font: theme.bodyFont,
                        .foregroundColor: theme.accentColor,
                        .paragraphStyle: paragraph,
                    ]
                )
            )
            appendInline(
                parts.text,
                style: InlineStyle(font: theme.bodyFont, color: theme.bodyColor)
            )
            appendNewline(with: paragraph)
            if parts.marker.last == "." {
                orderedIndex += 1
            }
            index += 1
        }
        return index
    }

    private func renderQuote(
        _ lines: [String],
        startingAt start: Int
    ) -> Int {
        var index = start
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else {
                break
            }
            let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 14
            paragraph.headIndent = 14
            paragraph.paragraphSpacing = 4
            paragraph.lineSpacing = 2
            attributedString.append(
                NSAttributedString(
                    string: "│ ",
                    attributes: [
                        .font: theme.bodyFont,
                        .foregroundColor: theme.accentColor,
                        .paragraphStyle: paragraph,
                    ]
                )
            )
            appendInline(
                String(body),
                style: InlineStyle(font: theme.bodyFont, color: theme.secondaryColor, italic: true)
            )
            appendNewline(with: paragraph)
            index += 1
        }
        return index
    }

    private func renderTable(
        _ lines: [String],
        startingAt start: Int
    ) -> Int {
        guard start >= 0,
              start + 1 < lines.count,
              let header = tableCells(in: lines[start])
        else {
            return start + 1
        }
        var rows = [header]
        var index = start + 2
        while index < lines.count,
              let row = tableCells(in: lines[index]),
              !row.isEmpty
        {
            rows.append(row)
            index += 1
        }
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else {
            return index
        }
        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.hidesEmptyCells = false
        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<columnCount {
                let value = column < row.count ? row[column] : ""
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: column,
                    columnSpan: 1
                )
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.backgroundColor = rowIndex == 0
                    ? theme.codeBackgroundColor
                    : NSColor.clear
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.paragraphSpacing = 0
                paragraph.lineSpacing = 2
                attributedString.append(
                    NSAttributedString(
                        string: "\(value)\n",
                        attributes: [
                            .font: rowIndex == 0
                                ? NSFont.systemFont(ofSize: theme.bodyFont.pointSize, weight: .semibold)
                                : theme.bodyFont,
                            .foregroundColor: theme.bodyColor,
                            .paragraphStyle: paragraph,
                        ]
                    )
                )
            }
        }
        return index
    }

    private func appendInline(_ text: String, style: InlineStyle) {
        let mathSpans = MathSyntax.mathSpans(in: text)
        var cursor = 0
        for span in mathSpans {
            if span.range.location > cursor {
                appendInlineMarkup(
                    (text as NSString).substring(
                        with: NSRange(
                            location: cursor,
                            length: span.range.location - cursor
                        )
                    ),
                    style: style
                )
            }
            if MathSyntax.isSupportedExpression(span.expression),
               let attachment = MathAttachmentFactory.make(
                   expression: span.expression,
                   display: span.isDisplay,
                   color: style.color
               )
            {
                attributedString.append(NSAttributedString(attachment: attachment))
                hasMathAttachments = true
            } else {
                fallbackMathSources.append(span.source)
                attributedString.append(
                    NSAttributedString(
                        string: span.source,
                        attributes: [
                            .font: theme.codeFont,
                            .foregroundColor: style.color,
                            .backgroundColor: theme.codeBackgroundColor,
                        ]
                    )
                )
            }
            cursor = span.range.location + span.range.length
        }
        if cursor < text.utf16.count {
            appendInlineMarkup(
                (text as NSString).substring(from: cursor),
                style: style
            )
        }
    }

    private func appendInlineMarkup(_ text: String, style: InlineStyle) {
        if MathSyntax.hasUnclosedMathDelimiter(in: text) {
            attributedString.append(
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: theme.codeFont,
                        .foregroundColor: style.color,
                        .backgroundColor: theme.codeBackgroundColor,
                    ]
                )
            )
            return
        }
        var index = text.startIndex
        var plainStart = index

        func flushPlain(to end: String.Index) {
            guard plainStart < end else {
                return
            }
            let value = String(text[plainStart..<end])
            attributedString.append(
                NSAttributedString(
                    string: value,
                    attributes: style.attributes
                )
            )
        }

        while index < text.endIndex {
            let remainder = text[index...]
            if remainder.hasPrefix("`") {
                if let closing = text[index...].dropFirst().firstIndex(of: "`") {
                    flushPlain(to: index)
                    let codeStart = text.index(after: index)
                    let code = String(text[codeStart..<closing])
                    attributedString.append(
                        NSAttributedString(
                            string: code,
                            attributes: [
                                .font: theme.codeFont,
                                .foregroundColor: style.color,
                                .backgroundColor: theme.codeBackgroundColor,
                            ]
                        )
                    )
                    index = text.index(after: closing)
                    plainStart = index
                    continue
                }
            }

            if let marker = emphasisMarker(at: index, in: text),
               let closing = text[index...].dropFirst(marker.count)
                   .firstRange(of: marker)
            {
                flushPlain(to: index)
                let contentStart = text.index(index, offsetBy: marker.count)
                let content = String(text[contentStart..<closing.lowerBound])
                appendInlineMarkup(content, style: style.with(marker: marker))
                index = closing.upperBound
                plainStart = index
                continue
            }

            if text[index] == "[",
               let closeBracket = text[index...].firstIndex(of: "]"),
               closeBracket < text.endIndex,
               text.index(after: closeBracket) < text.endIndex,
               text[text.index(after: closeBracket)] == "("
            {
                let urlStart = text.index(after: text.index(after: closeBracket))
                if let closeParen = text[urlStart...].firstIndex(of: ")") {
                    flushPlain(to: index)
                    let label = String(text[text.index(after: index)..<closeBracket])
                    attributedString.append(
                        NSAttributedString(
                            string: label,
                            attributes: [
                                .font: style.font,
                                .foregroundColor: theme.accentColor,
                                .underlineStyle: NSUnderlineStyle.single.rawValue,
                            ]
                        )
                    )
                    index = text.index(after: closeParen)
                    plainStart = index
                    continue
                }
            }

            if text[index] == "\\", index < text.index(before: text.endIndex) {
                let next = text.index(after: index)
                if "\\`*_{}[]()#+-.!~|>$".contains(text[next]) {
                    flushPlain(to: index)
                    if text[next] == "(" || text[next] == "[" {
                        // Valid math spans have already been removed by
                        // MathSyntax. A remaining canonical opener is a
                        // malformed equation, so preserve its source rather
                        // than interpreting it as a Markdown escape.
                        attributedString.append(
                            NSAttributedString(
                                string: String(text[index...]),
                                attributes: [
                                    .font: theme.codeFont,
                                    .foregroundColor: style.color,
                                    .backgroundColor: theme.codeBackgroundColor,
                                ]
                            )
                        )
                        return
                    }
                    attributedString.append(
                        NSAttributedString(
                            string: String(text[next]),
                            attributes: style.attributes
                        )
                    )
                    index = text.index(after: next)
                    plainStart = index
                    continue
                }
            }
            index = text.index(after: index)
        }
        flushPlain(to: text.endIndex)
    }

    private func emphasisMarker(
        at index: String.Index,
        in text: String
    ) -> String? {
        let remainder = text[index...]
        for marker in ["**", "__", "~~", "*", "_"] where remainder.hasPrefix(marker) {
            return marker
        }
        return nil
    }

    private func isFenceStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private func headingContent(in line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level),
              trimmed.count > level,
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)].isWhitespace
        else {
            return nil
        }
        let start = trimmed.index(trimmed.startIndex, offsetBy: level)
        return (
            level,
            trimmed[start...].trimmingCharacters(in: .whitespaces)
        )
    }

    private func listParts(in line: String) -> (marker: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }
        if ["-", "*", "+"].contains(String(trimmed.first!)),
           trimmed.count > 1
        {
            let split = trimmed.index(trimmed.startIndex, offsetBy: 1)
            guard trimmed[split].isWhitespace else {
                return nil
            }
            return (String(trimmed[..<split]), trimmed[split...].trimmingCharacters(in: .whitespaces))
        }
        var digitEnd = trimmed.startIndex
        while digitEnd < trimmed.endIndex, trimmed[digitEnd].isNumber {
            digitEnd = trimmed.index(after: digitEnd)
        }
        guard digitEnd > trimmed.startIndex,
              digitEnd < trimmed.endIndex,
              trimmed[digitEnd] == "."
        else {
            return nil
        }
        let afterDot = trimmed.index(after: digitEnd)
        guard afterDot < trimmed.endIndex, trimmed[afterDot].isWhitespace else {
            return nil
        }
        return (
            String(trimmed[trimmed.startIndex...digitEnd]),
            trimmed[afterDot...].trimmingCharacters(in: .whitespaces)
        )
    }

    private func isTableStart(at index: Int, in lines: [String]) -> Bool {
        guard index >= 0, index + 1 < lines.count,
              tableCells(in: lines[index]) != nil,
              let separator = tableCells(in: lines[index + 1])
        else {
            return false
        }
        return !separator.isEmpty
            && separator.allSatisfy {
                let value = $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return value.count >= 3 && value.allSatisfy { $0 == "-" }
            }
    }

    private func tableCells(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else {
            return nil
        }
        var value = trimmed
        if value.hasPrefix("|") {
            value.removeFirst()
        }
        if value.hasSuffix("|") {
            value.removeLast()
        }
        return value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

@MainActor
private struct InlineStyle {
    let font: NSFont
    let color: NSColor
    var bold = false
    var italic = false

    var attributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if bold {
            attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if italic {
            attributes[.obliqueness] = 0.15
        }
        return attributes
    }

    func with(marker: String) -> InlineStyle {
        var copy = self
        if marker == "**" || marker == "__" {
            copy.bold = true
        } else if marker == "*" || marker == "_" {
            copy.italic = true
        }
        return copy
    }
}

private extension String.SubSequence {
    func firstRange(of value: String) -> Range<String.Index>? {
        range(of: value)
    }
}

@MainActor
private enum MathAttachmentFactory {
    static func make(
        expression: String,
        display: Bool,
        color: NSColor
    ) -> NSTextAttachment? {
        guard let result = NativeMathImageRenderer(
            expression: expression,
            display: display,
            color: color
        ).render()
        else {
            return nil
        }
        let attachment = NSTextAttachment()
        attachment.image = result.image
        attachment.bounds = NSRect(
            x: 0,
            y: -result.descent,
            width: result.image.size.width,
            height: result.image.size.height
        )
        return attachment
    }
}

private indirect enum MathNode {
    case sequence([MathNode])
    case text(String)
    case fraction(MathNode, MathNode)
    case radical(MathNode)
    case scripts(base: MathNode, superscript: MathNode?, subscriptNode: MathNode?)
}

@MainActor
private final class NativeMathImageRenderer {
    private let expression: String
    private let display: Bool
    private let color: NSColor
    private let baseFont: NSFont

    init(expression: String, display: Bool, color: NSColor) {
        self.expression = expression
        self.display = display
        self.color = color
        baseFont = NSFont.systemFont(ofSize: display ? 18 : 15)
    }

    struct RenderResult {
        let image: NSImage
        let descent: CGFloat
    }

    func render() -> RenderResult? {
        guard let node = MathExpressionParser(expression: expression).parse() else {
            return nil
        }
        let metrics = measure(node, font: baseFont)
        let size = NSSize(
            width: max(4, ceil(metrics.width + 6)),
            height: max(4, ceil(metrics.ascent + metrics.descent + 6))
        )
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(
            node,
            at: NSPoint(x: 3, y: 3 + metrics.descent),
            font: baseFont
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return RenderResult(image: image, descent: metrics.descent)
    }

    private struct Metrics {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    private func measure(_ node: MathNode, font: NSFont) -> Metrics {
        switch node {
        case let .text(value):
            let rect = (value as NSString).size(withAttributes: [.font: font])
            return Metrics(width: rect.width, ascent: font.ascender, descent: -font.descender)
        case let .sequence(nodes):
            let values = nodes.map { measure($0, font: font) }
            return Metrics(
                width: values.reduce(0) { $0 + $1.width },
                ascent: values.map(\.ascent).max() ?? font.ascender,
                descent: values.map(\.descent).max() ?? -font.descender
            )
        case let .fraction(numerator, denominator):
            let smallFont = NSFont.systemFont(ofSize: font.pointSize * 0.72)
            let top = measure(numerator, font: smallFont)
            let bottom = measure(denominator, font: smallFont)
            return Metrics(
                width: max(top.width, bottom.width) + 8,
                ascent: top.ascent + top.descent + 4,
                descent: bottom.ascent + bottom.descent + 4
            )
        case let .radical(content):
            let inner = measure(content, font: font)
            let root = ("√" as NSString).size(withAttributes: [.font: font])
            return Metrics(
                width: root.width + inner.width + 2,
                ascent: max(root.height, inner.ascent),
                descent: inner.descent
            )
        case let .scripts(base, superscript, subscriptNode):
            let baseMetrics = measure(base, font: font)
            let scriptFont = NSFont.systemFont(ofSize: font.pointSize * 0.62)
            let superMetrics = superscript.map { measure($0, font: scriptFont) }
            let subMetrics = subscriptNode.map { measure($0, font: scriptFont) }
            let scriptWidth = max(superMetrics?.width ?? 0, subMetrics?.width ?? 0)
            return Metrics(
                width: baseMetrics.width + scriptWidth,
                ascent: baseMetrics.ascent + (superMetrics?.ascent ?? 0) * 0.72,
                descent: baseMetrics.descent + (subMetrics?.descent ?? 0) * 0.72
            )
        }
    }

    private func draw(_ node: MathNode, at point: NSPoint, font: NSFont) {
        switch node {
        case let .text(value):
            (value as NSString).draw(
                at: point,
                withAttributes: [.font: font, .foregroundColor: color]
            )
        case let .sequence(nodes):
            var x = point.x
            for child in nodes {
                let metrics = measure(child, font: font)
                draw(child, at: NSPoint(x: x, y: point.y), font: font)
                x += metrics.width
            }
        case let .fraction(numerator, denominator):
            let smallFont = NSFont.systemFont(ofSize: font.pointSize * 0.72)
            let top = measure(numerator, font: smallFont)
            let bottom = measure(denominator, font: smallFont)
            let width = max(top.width, bottom.width)
            draw(
                numerator,
                at: NSPoint(x: point.x + (width - top.width) / 2, y: point.y + bottom.ascent + bottom.descent + 3),
                font: smallFont
            )
            let lineY = point.y + bottom.ascent + bottom.descent + 1
            let path = NSBezierPath()
            path.move(to: NSPoint(x: point.x, y: lineY))
            path.line(to: NSPoint(x: point.x + width + 8, y: lineY))
            path.lineWidth = max(1, font.pointSize / 14)
            color.setStroke()
            path.stroke()
            draw(
                denominator,
                at: NSPoint(x: point.x + (width - bottom.width) / 2, y: point.y),
                font: smallFont
            )
        case let .radical(content):
            let root = "√" as NSString
            let rootSize = root.size(withAttributes: [.font: font])
            root.draw(
                at: point,
                withAttributes: [.font: font, .foregroundColor: color]
            )
            let innerPoint = NSPoint(x: point.x + rootSize.width, y: point.y)
            draw(content, at: innerPoint, font: font)
            let inner = measure(content, font: font)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: innerPoint.x, y: point.y + font.ascender + 1))
            path.line(to: NSPoint(x: innerPoint.x + inner.width, y: point.y + font.ascender + 1))
            path.lineWidth = max(1, font.pointSize / 14)
            color.setStroke()
            path.stroke()
        case let .scripts(base, superscript, subscriptNode):
            let baseMetrics = measure(base, font: font)
            draw(base, at: point, font: font)
            let scriptFont = NSFont.systemFont(ofSize: font.pointSize * 0.62)
            if let superscript {
                draw(
                    superscript,
                    at: NSPoint(x: point.x + baseMetrics.width, y: point.y + font.ascender * 0.70),
                    font: scriptFont
                )
            }
            if let subscriptNode {
                draw(
                    subscriptNode,
                    at: NSPoint(x: point.x + baseMetrics.width, y: point.y - font.descender * 0.55),
                    font: scriptFont
                )
            }
        }
    }
}

private final class MathExpressionParser {
    private let characters: [Character]
    private var index = 0

    init(expression: String) {
        characters = Array(expression)
    }

    func parse() -> MathNode? {
        guard let result = parseSequence(until: nil), index == characters.count else {
            return nil
        }
        return result
    }

    private func parseSequence(until closing: Character?) -> MathNode? {
        var nodes: [MathNode] = []
        while index < characters.count {
            if let closing, characters[index] == closing {
                index += 1
                break
            }
            if characters[index] == "^" || characters[index] == "_" {
                guard !nodes.isEmpty else {
                    return nil
                }
                let isSuper = characters[index] == "^"
                index += 1
                guard let script = parseArgument() else {
                    return nil
                }
                nodes[nodes.count - 1] = applyScript(
                    to: nodes[nodes.count - 1],
                    script: script,
                    isSuper: isSuper
                )
                continue
            }
            guard let atom = parseAtom() else {
                return nil
            }
            nodes.append(atom)
        }
        guard !nodes.isEmpty, closing == nil || index <= characters.count else {
            return nil
        }
        return nodes.count == 1 ? nodes[0] : .sequence(nodes)
    }

    private func parseArgument() -> MathNode? {
        guard index < characters.count else {
            return nil
        }
        if characters[index] == "{" {
            index += 1
            return parseSequence(until: "}")
        }
        return parseAtom()
    }

    private func parseAtom() -> MathNode? {
        guard index < characters.count else {
            return nil
        }
        let character = characters[index]
        if character == "{" {
            index += 1
            return parseSequence(until: "}")
        }
        if character == "\\" {
            return parseCommand()
        }
        if character.isWhitespace {
            index += 1
            return .text(" ")
        }
        guard character != "}" && character != "]" && character != "&" else {
            return nil
        }
        index += 1
        return .text(String(character))
    }

    private func parseCommand() -> MathNode? {
        index += 1
        guard index < characters.count else {
            return nil
        }
        let start = index
        while index < characters.count, characters[index].isLetter {
            index += 1
        }
        if start == index {
            let symbol = characters[index]
            index += 1
            switch symbol {
            case ",", ";", "!":
                return .text(" ")
            case "\\":
                return nil
            default:
                return .text(String(symbol))
            }
        }
        let command = String(characters[start..<index])
        switch command {
        case "frac":
            guard let numerator = parseArgument(),
                  let denominator = parseArgument()
            else { return nil }
            return .fraction(numerator, denominator)
        case "sqrt":
            guard let content = parseArgument() else { return nil }
            return .radical(content)
        case "left", "right":
            return .text("")
        default:
            guard let symbol = Self.symbols[command] else {
                return nil
            }
            return .text(symbol)
        }
    }

    private func applyScript(
        to base: MathNode,
        script: MathNode,
        isSuper: Bool
    ) -> MathNode {
        switch base {
        case let .scripts(base, superscript, subscriptNode):
            return .scripts(
                base: base,
                superscript: isSuper ? script : superscript,
                subscriptNode: isSuper ? subscriptNode : script
            )
        default:
            return .scripts(
                base: base,
                superscript: isSuper ? script : nil,
                subscriptNode: isSuper ? nil : script
            )
        }
    }

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ",
        "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ",
        "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω", "sum": "∑", "prod": "∏",
        "int": "∫", "oint": "∮", "times": "×", "cdot": "·", "pm": "±",
        "mp": "∓", "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "neq": "≠",
        "approx": "≈", "sim": "∼", "equiv": "≡", "infty": "∞", "partial": "∂",
        "nabla": "∇", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "to": "→", "in": "∈", "notin": "∉", "subset": "⊂",
        "subseteq": "⊆", "cup": "∪", "cap": "∩", "forall": "∀", "exists": "∃",
        "sin": "sin", "cos": "cos", "tan": "tan", "cot": "cot", "sec": "sec",
        "csc": "csc", "log": "log", "ln": "ln", "exp": "exp", "lim": "lim",
    ]
}
