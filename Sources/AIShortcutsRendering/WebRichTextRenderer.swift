import AIShortcutsCore
import Foundation

@MainActor
public final class WebRichTextRenderer {
    public var resourceBaseURL: URL? {
        Self.resourceBundle?.resourceURL
    }

    public init() {
    }

    public func render(_ document: AIOutputDocument) -> String {
        let displayDocument = Self.unwrappedTextDocument(from: document) ?? document
        guard (try? AIOutputDocumentValidator.validate(displayDocument)) != nil else {
            return renderPlainText(displayDocument.source)
        }
        guard displayDocument.format == .markdown else {
            return renderPlainText(displayDocument.source)
        }
        return renderMarkdown(displayDocument.source)
    }

    public func renderPlainText(_ text: String) -> String {
        "<p class=\"plain-text\">\(Self.escapeHTML(text, preservingLineBreaks: true))</p>"
    }

    public func htmlDocument(body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="dark">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; font-src 'self';">
          <link rel="stylesheet" href="KaTeX/katex.min.css">
          <style>
            :root {
              color-scheme: dark;
              --shell: #1b1c20;
              --raised: #27292e;
              --user-surface: #272633;
              --primary: #f6f7fa;
              --secondary: #aeb1bd;
              --muted: #7d8190;
              --accent: #8074fb;
              --accent-soft: rgba(128, 116, 251, 0.34);
              --border: rgba(255, 255, 255, 0.10);
            }

            * { box-sizing: border-box; }

            html, body {
              margin: 0;
              min-height: 100%;
              background: transparent;
            }

            body {
              color: var(--primary);
              font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
              font-size: 15px;
              line-height: 1.48;
              -webkit-font-smoothing: antialiased;
              -webkit-user-select: text;
              overflow-wrap: anywhere;
            }

            .transcript {
              width: 100%;
              min-height: 100%;
              padding: 10px 8px 22px;
            }

            .message-user {
              margin: 0 0 28px;
              padding: 14px 16px;
              border: 1px solid var(--accent-soft);
              border-radius: 14px;
              background: var(--user-surface);
              color: var(--accent);
              font-size: 15px;
              line-height: 1.45;
              white-space: pre-wrap;
            }

            .message-user p,
            .message-assistant p,
            .plain-text {
              margin: 0;
            }

            .message-assistant {
              margin: 0 4px 30px;
              color: var(--primary);
            }

            .message-assistant p { margin: 0 0 13px; }
            .message-assistant p:last-child { margin-bottom: 0; }

            h1, h2, h3, h4, h5, h6 {
              margin: 0 0 14px;
              color: var(--primary);
              line-height: 1.22;
            }

            h1 { font-size: 22px; }
            h2 { font-size: 20px; }
            h3 { font-size: 18px; }
            h4, h5, h6 { font-size: 16px; }

            ul, ol {
              margin: 0 0 14px;
              padding-left: 24px;
            }

            li { padding-left: 3px; margin: 0 0 5px; }
            li::marker { color: var(--accent); }

            blockquote {
              margin: 0 0 14px;
              padding-left: 14px;
              border-left: 1px solid var(--accent);
              color: var(--secondary);
              font-style: italic;
            }

            code, pre {
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
              font-size: 0.88em;
            }

            code {
              padding: 1px 4px;
              border-radius: 4px;
              background: rgba(255, 255, 255, 0.09);
            }

            pre {
              margin: 0 0 14px;
              padding: 11px 12px;
              border: 1px solid var(--border);
              border-radius: 10px;
              background: rgba(255, 255, 255, 0.06);
              color: var(--primary);
              line-height: 1.42;
              white-space: pre-wrap;
              overflow-x: auto;
            }

            pre code {
              padding: 0;
              background: transparent;
            }

            .link {
              color: var(--accent);
              text-decoration: underline;
              text-decoration-thickness: 1px;
              text-underline-offset: 2px;
            }

            .math-inline {
              color: var(--primary);
              white-space: nowrap;
            }

            .math-block {
              margin: 10px 0 16px;
              padding: 5px 2px;
              color: var(--primary);
              text-align: center;
              overflow-x: auto;
              overflow-y: hidden;
              scrollbar-width: none;
            }

            .math-block::-webkit-scrollbar { display: none; }
            .katex { color: inherit; font-size: 1.12em; }
            .katex-display { margin: 0; }
            .katex-error { color: var(--accent); }

            table {
              width: 100%;
              margin: 0 0 14px;
              border-collapse: separate;
              border-spacing: 0;
              overflow: hidden;
              border: 1px solid var(--border);
              border-radius: 9px;
            }

            th, td {
              padding: 7px 9px;
              border-right: 1px solid var(--border);
              border-bottom: 1px solid var(--border);
              text-align: left;
              vertical-align: top;
            }

            th:last-child, td:last-child { border-right: 0; }
            tr:last-child td { border-bottom: 0; }
            th {
              background: rgba(255, 255, 255, 0.07);
              font-weight: 600;
            }

            .status {
              margin: 10px 4px 0;
              color: var(--secondary);
            }

            .error { color: #daa26e; }
            ::selection { background: rgba(128, 116, 251, 0.34); }
          </style>
        </head>
        <body>
          \(body)
          <script src="KaTeX/katex.min.js"></script>
          <script>
            (() => {
              const renderMath = () => {
                document.querySelectorAll('[data-math]').forEach((node) => {
                  const source = node.textContent || '';
                  node.textContent = '';
                  try {
                    katex.render(source, node, {
                      displayMode: node.dataset.display === 'true',
                      output: 'htmlAndMathml',
                      throwOnError: false,
                      strict: 'ignore',
                      trust: false
                    });
                  } catch (_) {
                    node.textContent = source;
                    node.classList.add('math-failed');
                  }
                });
              };
              renderMath();
              document.documentElement.dataset.ready = 'true';
            })();
          </script>
        </body>
        </html>
        """
    }

    private func renderMarkdown(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var output = ""
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            if isFenceStart(line) {
                index = renderCodeBlock(lines, startingAt: index, into: &output)
                continue
            }
            if isTableStart(at: index, in: lines) {
                index = renderTable(lines, startingAt: index, into: &output)
                continue
            }
            if let heading = headingContent(in: line) {
                output += "<h\(heading.level)>\(renderInline(heading.text))</h\(heading.level)>"
                index += 1
                continue
            }
            if listParts(in: line) != nil {
                index = renderList(lines, startingAt: index, into: &output)
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                index = renderQuote(lines, startingAt: index, into: &output)
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
            output += renderFlow(paragraphLines.joined(separator: "\n"))
        }

        return output
    }

    private func renderFlow(_ text: String) -> String {
        let displaySpans = MathSyntax.mathSpans(in: text).filter(\.isDisplay)
        guard !displaySpans.isEmpty else {
            return "<p>\(renderInline(text))</p>"
        }

        var output = ""
        var cursor = 0
        for span in displaySpans {
            if span.range.location > cursor {
                let before = (text as NSString).substring(
                    with: NSRange(
                        location: cursor,
                        length: span.range.location - cursor
                    )
                )
                if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output += "<p>\(renderInline(before))</p>"
                }
            }
            output += mathMarkup(
                expression: span.expression,
                display: true,
                block: true
            )
            cursor = span.range.location + span.range.length
        }
        if cursor < text.utf16.count {
            let after = (text as NSString).substring(from: cursor)
            if !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output += "<p>\(renderInline(after))</p>"
            }
        }
        return output
    }

    private func renderCodeBlock(
        _ lines: [String],
        startingAt start: Int,
        into output: inout String
    ) -> Int {
        var index = start + 1
        var codeLines: [String] = []
        while index < lines.count, !isFenceStart(lines[index]) {
            codeLines.append(lines[index])
            index += 1
        }
        let code = Self.escapeHTML(codeLines.joined(separator: "\n"))
        output += "<pre><code>\(code)</code></pre>"
        return min(lines.count, index + 1)
    }

    private func renderList(
        _ lines: [String],
        startingAt start: Int,
        into output: inout String
    ) -> Int {
        guard let first = listParts(in: lines[start]) else {
            return start + 1
        }
        let ordered = first.marker.last == "."
        output += ordered ? "<ol>" : "<ul>"
        var index = start
        while index < lines.count, let parts = listParts(in: lines[index]) {
            output += "<li>\(renderInline(parts.text, displayMathAsInline: true))</li>"
            index += 1
        }
        output += ordered ? "</ol>" : "</ul>"
        return index
    }

    private func renderQuote(
        _ lines: [String],
        startingAt start: Int,
        into output: inout String
    ) -> Int {
        var index = start
        var bodies: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else {
                break
            }
            bodies.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            index += 1
        }
        output += "<blockquote>\(renderInline(bodies.joined(separator: "\n")))</blockquote>"
        return index
    }

    private func renderTable(
        _ lines: [String],
        startingAt start: Int,
        into output: inout String
    ) -> Int {
        guard start + 1 < lines.count,
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

        output += "<table><thead><tr>"
        for cell in header {
            output += "<th>\(renderInline(cell, displayMathAsInline: true))</th>"
        }
        output += "</tr></thead>"
        if rows.count > 1 {
            output += "<tbody>"
            for row in rows.dropFirst() {
                output += "<tr>"
                for column in 0..<header.count {
                    let cell = column < row.count ? row[column] : ""
                    output += "<td>\(renderInline(cell, displayMathAsInline: true))</td>"
                }
                output += "</tr>"
            }
            output += "</tbody>"
        }
        output += "</table>"
        return index
    }

    private func renderInline(
        _ text: String,
        displayMathAsInline: Bool = false
    ) -> String {
        let mathSpans = MathSyntax.mathSpans(in: text)
        guard !mathSpans.isEmpty else {
            return renderInlineMarkup(text)
        }

        var output = ""
        var cursor = 0
        for span in mathSpans {
            if span.range.location > cursor {
                output += renderInlineMarkup(
                    (text as NSString).substring(
                        with: NSRange(
                            location: cursor,
                            length: span.range.location - cursor
                        )
                    )
                )
            }
            output += mathMarkup(
                expression: span.expression,
                display: span.isDisplay && !displayMathAsInline,
                block: span.isDisplay && !displayMathAsInline
            )
            cursor = span.range.location + span.range.length
        }
        if cursor < text.utf16.count {
            output += renderInlineMarkup((text as NSString).substring(from: cursor))
        }
        return output
    }

    private func mathMarkup(
        expression: String,
        display: Bool,
        block: Bool
    ) -> String {
        let escaped = Self.escapeHTML(
            expression.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let attributes = "data-math data-display=\"\(display ? "true" : "false")\""
        if block {
            return "<div class=\"math-block\" \(attributes)>\(escaped)</div>"
        }
        return "<span class=\"math-inline\" \(attributes)>\(escaped)</span>"
    }

    private func renderInlineMarkup(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        var plainStart = index

        func flushPlain(to end: String.Index) {
            guard plainStart < end else { return }
            output += Self.escapeHTML(
                String(text[plainStart..<end]),
                preservingLineBreaks: true
            )
        }

        while index < text.endIndex {
            let remainder = text[index...]
            if remainder.hasPrefix("`") {
                if let closing = text[index...].dropFirst().firstIndex(of: "`") {
                    flushPlain(to: index)
                    let codeStart = text.index(after: index)
                    let code = String(text[codeStart..<closing])
                    output += "<code>\(Self.escapeHTML(code))</code>"
                    index = text.index(after: closing)
                    plainStart = index
                    continue
                }
            }

            if let marker = emphasisMarker(at: index, in: text),
               let closing = text[index...].dropFirst(marker.count)
                   .range(of: marker)?.lowerBound
            {
                flushPlain(to: index)
                let contentStart = text.index(index, offsetBy: marker.count)
                let content = String(text[contentStart..<closing])
                let tag = marker == "~~" ? "del" : (marker == "**" || marker == "__" ? "strong" : "em")
                output += "<\(tag)>\(renderInlineMarkup(content))</\(tag)>"
                index = text.index(closing, offsetBy: marker.count)
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
                    output += "<span class=\"link\">\(renderInlineMarkup(label))</span>"
                    index = text.index(after: closeParen)
                    plainStart = index
                    continue
                }
            }

            if text[index] == "\\", index < text.index(before: text.endIndex) {
                let next = text.index(after: index)
                if "\\`*_{}[]()#+-.!~|>$".contains(text[next]) {
                    flushPlain(to: index)
                    output += Self.escapeHTML(String(text[next]))
                    index = text.index(after: next)
                    plainStart = index
                    continue
                }
            }
            index = text.index(after: index)
        }
        flushPlain(to: text.endIndex)
        return output
    }

    private func emphasisMarker(at index: String.Index, in text: String) -> String? {
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
        return (level, trimmed[start...].trimmingCharacters(in: .whitespaces))
    }

    private func listParts(in line: String) -> (marker: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if ["-", "*", "+"].contains(String(trimmed.first!)), trimmed.count > 1 {
            let split = trimmed.index(trimmed.startIndex, offsetBy: 1)
            guard trimmed[split].isWhitespace else { return nil }
            return (String(trimmed[..<split]), trimmed[split...].trimmingCharacters(in: .whitespaces))
        }
        var digitEnd = trimmed.startIndex
        while digitEnd < trimmed.endIndex, trimmed[digitEnd].isNumber {
            digitEnd = trimmed.index(after: digitEnd)
        }
        guard digitEnd > trimmed.startIndex,
              digitEnd < trimmed.endIndex,
              trimmed[digitEnd] == "."
        else { return nil }
        let afterDot = trimmed.index(after: digitEnd)
        guard afterDot < trimmed.endIndex, trimmed[afterDot].isWhitespace else { return nil }
        return (String(trimmed[trimmed.startIndex...digitEnd]), trimmed[afterDot...].trimmingCharacters(in: .whitespaces))
    }

    private func isTableStart(at index: Int, in lines: [String]) -> Bool {
        guard index >= 0, index + 1 < lines.count,
              tableCells(in: lines[index]) != nil,
              let separator = tableCells(in: lines[index + 1])
        else { return false }
        return !separator.isEmpty && separator.allSatisfy {
            let value = $0.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }

    private func tableCells(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var value = trimmed
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func escapeHTML(
        _ text: String,
        preservingLineBreaks: Bool = false
    ) -> String {
        var escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
        if preservingLineBreaks {
            escaped = escaped.replacingOccurrences(of: "\n", with: "<br>\n")
        }
        return escaped
    }

    private static func unwrappedTextDocument(
        from document: AIOutputDocument
    ) -> AIOutputDocument? {
        guard document.format == .plainText,
              let data = document.source.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(TextDocumentEnvelope.self, from: data)
        else {
            return nil
        }
        return AIOutputDocument(format: envelope.format, source: envelope.content)
    }

    private struct TextDocumentEnvelope: Decodable {
        let format: AIOutputFormat
        let content: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            let keys = Set(container.allKeys.map(\.stringValue))
            guard keys == ["format", "content"] else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "The text document envelope must contain exactly format and content."
                    )
                )
            }
            self.format = try container.decode(
                AIOutputFormat.self,
                forKey: Key(stringValue: "format")!
            )
            self.content = try container.decode(
                String.self,
                forKey: Key(stringValue: "content")!
            )
        }

        private struct Key: CodingKey {
            let stringValue: String
            let intValue: Int?

            init?(stringValue: String) {
                self.stringValue = stringValue
                intValue = nil
            }

            init?(intValue: Int) {
                return nil
            }
        }
    }

    private static var resourceBundle: Bundle? {
        let bundleName = "AIShortcuts_AIShortcutsRendering.bundle"
        let installedCandidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
        ].compactMap { $0 }
        if let installedBundle = installedCandidates
            .compactMap(Bundle.init(url:))
            .first
        {
            return installedBundle
        }
        return Bundle.module
    }
}
