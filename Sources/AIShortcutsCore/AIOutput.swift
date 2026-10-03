import Foundation

public enum AIOutputFormat: String, Codable, Equatable, Sendable {
    case plainText = "plain_text"
    case markdown
}
public struct AIOutputDocument: Codable, Equatable, Sendable {
    public let format: AIOutputFormat
    public let source: String

    public init(
        format: AIOutputFormat,
        source: String,
        preserveTrailingLineBreaks: Bool = false
    ) {
        self.format = format
        self.source = Self.normalize(
            source,
            preserveTrailingLineBreaks: preserveTrailingLineBreaks
        )
    }

    public var isEmpty: Bool {
        source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalize(
        _ source: String,
        preserveTrailingLineBreaks: Bool
    ) -> String {
        let normalized = source
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        guard preserveTrailingLineBreaks else {
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let boundary = terminalLineBreaks(in: normalized)
        let bodyEnd = normalized.index(
            normalized.endIndex,
            offsetBy: -boundary.count
        )
        return normalized[..<bodyEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines) + boundary
    }

    private static func terminalLineBreaks(in source: String) -> String {
        var start = source.unicodeScalars.endIndex
        while start > source.unicodeScalars.startIndex {
            let previous = source.unicodeScalars.index(before: start)
            guard CharacterSet.newlines.contains(source.unicodeScalars[previous]) else {
                break
            }
            start = previous
        }
        return String(source[start..<source.endIndex])
    }
}

public enum AIOutputValidationError: LocalizedError, Equatable, Sendable {
    case empty
    case controlCharacter
    case rawHTML
    case embeddedImage
    case unsafeLink

    public var errorDescription: String? {
        switch self {
        case .empty:
            "The AI output was empty."
        case .controlCharacter:
            "The AI output contained an invalid control character."
        case .rawHTML:
            "The AI output contained raw HTML."
        case .embeddedImage:
            "The AI output contained an embedded image."
        case .unsafeLink:
            "The AI output contained an unsafe link."
        }
    }
}

public enum AIOutputDocumentValidator {
    public static func validate(_ document: AIOutputDocument) throws {
        guard !document.isEmpty else {
            throw AIOutputValidationError.empty
        }
        guard !document.source.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                && scalar.value != 10
                && scalar.value != 9
        }) else {
            throw AIOutputValidationError.controlCharacter
        }

        if document.format == .markdown {
            for line in visibleMarkdownLines(document.source) {
                if line.range(of: #"!\[[^\]]*\]\([^\)]*\)"#, options: .regularExpression) != nil {
                    throw AIOutputValidationError.embeddedImage
                }
                if line.range(
                    of: #"\]\(\s*(?:<\s*)?(?:javascript|data|file|vbscript|about):"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil {
                    throw AIOutputValidationError.unsafeLink
                }
                if line.range(of: #"</?[A-Za-z][^>]*>"#, options: .regularExpression) != nil {
                    throw AIOutputValidationError.rawHTML
                }
            }
        } else {
            if document.source.range(
                of: #"(?:javascript|vbscript|data|file|about):"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                throw AIOutputValidationError.unsafeLink
            }
            if document.source.range(
                of: #"<(?:script|iframe|object|embed|applet)\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                throw AIOutputValidationError.rawHTML
            }
        }
    }

    private static func visibleMarkdownLines(_ source: String) -> [String] {
        var lines: [String] = []
        var inFence = false
        for rawLine in source.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence else {
                continue
            }
            lines.append(stripInlineCode(from: rawLine))
        }
        return lines
    }

    private static func stripInlineCode(from line: String) -> String {
        var result = ""
        var inCode = false
        for character in line {
            if character == "`" {
                inCode.toggle()
                continue
            }
            if !inCode {
                result.append(character)
            }
        }
        return result
    }
}

public enum AIOutputFormatDetector {
    public static func detect(_ source: String) -> AIOutputFormat {
        guard !source.isEmpty else {
            return .plainText
        }

        let markdownMarkers = [
            "**",
            "__",
            "```",
            "~~",
            "\\(",
            "\\[",
            "$$",
        ]
        if markdownMarkers.contains(where: source.contains) {
            return .markdown
        }

        let blockPattern = #"(?m)^\s{0,3}(?:#{1,6}\s|[-*+]\s|\d+\.\s|>\s|\|.+\|)"#
        if source.range(of: blockPattern, options: .regularExpression) != nil {
            return .markdown
        }

        let linkPattern = #"\[[^\]]+\]\([^\)]+\)"#
        if source.range(of: linkPattern, options: .regularExpression) != nil {
            return .markdown
        }

        return .plainText
    }
}

public enum AIOutputPolicy {
    public static func allowedFormats(
        for action: AIShortcutAction,
        selectedText: String? = nil,
        parameter: String? = nil
    ) -> [AIOutputFormat] {
        switch action {
        case .ocr:
            return [.plainText]
        case .refine, .translate:
            return [AIOutputFormatDetector.detect(selectedText ?? "")]
        case .format:
            return formatInstructionRequestsMarkdown(parameter ?? "")
                ? [.markdown]
                : [.plainText]
        case .explain, .calculate:
            return [.plainText, .markdown]
        case .finderPath, .inputLock, .clipboardQueue, .insert, .chatgptVoice:
            return [.plainText]
        }
    }

    public static func formatInstructionRequestsMarkdown(_ instruction: String) -> Bool {
        let normalized = instruction
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let markers = [
            "markdown",
            "bullet",
            "list",
            "heading",
            "table",
            "blockquote",
            "quote",
            "code block",
            "inline code",
            "bold",
            "italic",
            "latex",
            "equation",
            "math",
        ]
        return markers.contains(where: normalized.contains)
    }

    public static func promptInstruction(
        for allowedFormats: [AIOutputFormat],
        field: String = "content"
    ) -> String {
        let formats = allowedFormats.map(\.rawValue).joined(separator: " or ")
        return """
        Return exactly one JSON object with the fields `format` and `\(field)`, with no code fence or commentary. The `format` value must be \(formats). When using Markdown, use Markdown only for useful structure, use \\(...\\) for inline equations and \\[...\\] for display equations, and never use raw HTML, embedded images, or executable links. After JSON decoding, every LaTeX delimiter and command must contain exactly one backslash; JSON escaping must not leave doubled backslashes in the decoded Markdown. When using plain_text, preserve literal punctuation and source markers instead of interpreting them.
        """
    }
}

public enum AIOutputDocumentSanitizer {
    public static func sanitizeGlitchMarkers(_ text: String) -> String {
        var cleaned = text
        // 1. Remove reasoning / thought tags from DeepSeek R1, Qwen, etc.
        let thoughtPattern = #"(?i)<(think|thought|reasoning)\b[^>]*>[\s\S]*?</\1>"#
        if let regex = try? NSRegularExpression(pattern: thoughtPattern) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        let unclosedThoughtPattern = #"(?i)<(think|thought|reasoning)\b[^>]*>[\s\S]*$"#
        if let regex = try? NSRegularExpression(pattern: unclosedThoughtPattern) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        // 2. Remove assistant header tokens
        let assistantPattern = #"(?:\s*##\s*assistant\b|\s*<\|(?:im_start|start_header_id|end_header_id|im_end)\|>).*"#
        if let regex = try? NSRegularExpression(pattern: assistantPattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        // 3. Convert harmless HTML breaks to standard newlines
        let brPattern = #"(?i)<br\s*/?>"#
        if let regex = try? NSRegularExpression(pattern: brPattern) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "\n")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func unwrapTextDocument(from document: AIOutputDocument) -> AIOutputDocument? {
        guard document.format == .plainText else {
            return nil
        }
        return extractTextDocument(from: document.source)
    }

    public static func unwrapOrSanitize(_ document: AIOutputDocument) -> AIOutputDocument {
        let resolved = unwrapTextDocument(from: document) ?? document
        let terminalBoundary = terminalLineBreaks(in: resolved.source)
        let sanitized = sanitizeGlitchMarkers(resolved.source)
        let repaired = resolved.format == .markdown
            ? repairMarkdownMathEscaping(sanitized)
            : sanitized
        return AIOutputDocument(
            format: resolved.format,
            source: repaired + terminalBoundary,
            preserveTrailingLineBreaks: !terminalBoundary.isEmpty
        )
    }

    private static func terminalLineBreaks(in source: String) -> String {
        var start = source.unicodeScalars.endIndex
        while start > source.unicodeScalars.startIndex {
            let previous = source.unicodeScalars.index(before: start)
            guard CharacterSet.newlines.contains(source.unicodeScalars[previous]) else {
                break
            }
            start = previous
        }
        return String(source[start..<source.endIndex])
    }

    /// Repairs a provider occasionally adding one escaping layer to Markdown
    /// math delimiters (for example `\\(` in the decoded content instead of
    /// `\(`). Only paired delimiters outside fenced and inline code are
    /// changed; LaTeX commands and line breaks inside an expression are left
    /// untouched. A multiline parenthesized expression is promoted to display
    /// math because canonical inline math cannot span paragraphs reliably.
    private static func repairMarkdownMathEscaping(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.utf8.count)

        var index = source.startIndex
        var isLineStart = true
        var inFence = false
        var inlineCodeTicks: Int?

        while index < source.endIndex {
            if isLineStart, inlineCodeTicks == nil {
                let lineEnd = source[index...].firstIndex(of: "\n") ?? source.endIndex
                let line = source[index..<lineEnd]
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    let consumedEnd = lineEnd < source.endIndex
                        ? source.index(after: lineEnd)
                        : lineEnd
                    result.append(contentsOf: source[index..<consumedEnd])
                    inFence.toggle()
                    index = consumedEnd
                    isLineStart = true
                    continue
                }
            }

            let character = source[index]
            if character == "\n" {
                result.append(character)
                index = source.index(after: index)
                isLineStart = true
                continue
            }
            isLineStart = false

            if inFence {
                result.append(character)
                index = source.index(after: index)
                continue
            }

            if character == "`" {
                var runEnd = index
                var runLength = 0
                while runEnd < source.endIndex, source[runEnd] == "`" {
                    runLength += 1
                    runEnd = source.index(after: runEnd)
                }
                result.append(contentsOf: source[index..<runEnd])
                if let openingTicks = inlineCodeTicks {
                    if openingTicks == runLength {
                        inlineCodeTicks = nil
                    }
                } else {
                    inlineCodeTicks = runLength
                }
                index = runEnd
                continue
            }

            if inlineCodeTicks == nil,
               let canonicalEnd = canonicalMathEnd(in: source, at: index)
            {
                result.append(contentsOf: source[index..<canonicalEnd])
                index = canonicalEnd
                continue
            }

            if inlineCodeTicks == nil,
               let opener = doubledMathOpener(in: source, at: index),
               let closingRange = source.range(
                   of: opener.doubledClosing,
                   range: opener.expressionStart..<source.endIndex
               )
            {
                let expression = String(source[opener.expressionStart..<closingRange.lowerBound])
                let isMultiline = expression.contains("\n")
                result += isMultiline ? "\\[" : opener.canonicalOpening
                result += expression
                result += isMultiline ? "\\]" : opener.canonicalClosing
                index = closingRange.upperBound
                isLineStart = expression.last == "\n"
                continue
            }

            result.append(character)
            index = source.index(after: index)
        }

        return result
    }

    private static func canonicalMathEnd(
        in source: String,
        at index: String.Index
    ) -> String.Index? {
        guard index == source.startIndex
                || source[source.index(before: index)] != "\\"
        else {
            return nil
        }
        let closingCharacter: Character
        if source[index...].hasPrefix("\\(") {
            closingCharacter = ")"
        } else if source[index...].hasPrefix("\\[") {
            closingCharacter = "]"
        } else {
            return nil
        }

        var cursor = source.index(index, offsetBy: 2)
        while cursor < source.endIndex {
            guard source[cursor] == "\\" else {
                cursor = source.index(after: cursor)
                continue
            }
            var slashCount = 0
            while cursor < source.endIndex, source[cursor] == "\\" {
                slashCount += 1
                cursor = source.index(after: cursor)
            }
            if slashCount.isMultiple(of: 2) == false,
               cursor < source.endIndex,
               source[cursor] == closingCharacter
            {
                return source.index(after: cursor)
            }
        }
        return nil
    }

    private static func doubledMathOpener(
        in source: String,
        at index: String.Index
    ) -> (
        expressionStart: String.Index,
        doubledClosing: String,
        canonicalOpening: String,
        canonicalClosing: String
    )? {
        guard source[index...].hasPrefix("\\\\(")
                || source[index...].hasPrefix("\\\\[")
        else {
            return nil
        }
        if index > source.startIndex,
           source[source.index(before: index)] == "\\"
        {
            return nil
        }
        let delimiterEnd = source.index(index, offsetBy: 3)
        if source[index...].hasPrefix("\\\\(") {
            return (delimiterEnd, "\\\\)", "\\(", "\\)")
        }
        return (delimiterEnd, "\\\\]", "\\[", "\\]")
    }

    public static func extractJSONPayload(from source: String) -> Data? {
        var textToScan = sanitizeGlitchMarkers(source)

        let fencePattern = #"(?s)^\s*```(?:json)?\s*\n?(.*?)\n?```\s*$"#
        if let regex = try? NSRegularExpression(pattern: fencePattern),
           let match = regex.firstMatch(in: textToScan, range: NSRange(textToScan.startIndex..<textToScan.endIndex, in: textToScan)),
           let bodyRange = Range(match.range(at: 1), in: textToScan) {
            textToScan = String(textToScan[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if textToScan.hasPrefix("```") {
            let lines = textToScan.components(separatedBy: "\n")
            if lines.count >= 2, lines.first?.hasPrefix("```") == true, lines.last?.hasPrefix("```") == true {
                textToScan = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let data = textToScan.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        guard let start = textToScan.firstIndex(of: "{") else {
            return nil
        }
        var depth = 0
        var inString = false
        var escape = false
        var index = start
        while index < textToScan.endIndex {
            let ch = textToScan[index]
            if escape {
                escape = false
            } else if ch == "\\" {
                if inString { escape = true }
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let jsonSubstring = textToScan[start...index]
                        if let data = jsonSubstring.data(using: .utf8),
                           (try? JSONSerialization.jsonObject(with: data)) != nil {
                            return data
                        }
                    }
                }
            }
            index = textToScan.index(after: index)
        }
        return nil
    }


    public static func extractTextDocument(from source: String) -> AIOutputDocument? {
        var textToScan = sanitizeGlitchMarkers(source)

        let fencePattern = #"(?s)^\s*```(?:json)?\s*\n?(.*?)\n?```\s*$"#
        if let regex = try? NSRegularExpression(pattern: fencePattern),
           let match = regex.firstMatch(in: textToScan, range: NSRange(textToScan.startIndex..<textToScan.endIndex, in: textToScan)),
           let bodyRange = Range(match.range(at: 1), in: textToScan) {
            textToScan = String(textToScan[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if textToScan.hasPrefix("```") {
            let lines = textToScan.components(separatedBy: "\n")
            if lines.count >= 2, lines.first?.hasPrefix("```") == true, lines.last?.hasPrefix("```") == true {
                textToScan = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        func documentFromJSON(_ json: [String: Any]) -> AIOutputDocument? {
            let possibleContent = json["content"]
                ?? json["answer"]
                ?? json["explanation"]
                ?? json["text"]
                ?? json["result"]
                ?? json["response"]
                ?? json["output"]
            guard let contentStr = possibleContent as? String else {
                return nil
            }
            let format: AIOutputFormat
            if let formatStr = json["format"] as? String, let parsed = AIOutputFormat(rawValue: formatStr) {
                format = parsed
            } else {
                format = AIOutputFormatDetector.detect(contentStr)
            }
            let cleanedContent = sanitizeGlitchMarkers(contentStr)
            if let nested = extractTextDocument(from: cleanedContent) {
                return nested
            }
            return AIOutputDocument(format: format, source: cleanedContent)
        }

        if let data = textToScan.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let doc = documentFromJSON(json) {
            return doc
        }

        guard let start = textToScan.firstIndex(of: "{") else {
            return nil
        }
        var depth = 0
        var inString = false
        var escape = false
        var index = start
        while index < textToScan.endIndex {
            let ch = textToScan[index]
            if escape {
                escape = false
            } else if ch == "\\" {
                if inString { escape = true }
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let jsonSubstring = textToScan[start...index]
                        if let data = jsonSubstring.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let doc = documentFromJSON(json) {
                            return doc
                        }
                    }
                }
            }
            index = textToScan.index(after: index)
        }
        return nil
    }
}
