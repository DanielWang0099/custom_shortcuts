import Foundation

public enum AIOutputFormat: String, Codable, Equatable, Sendable {
    case plainText = "plain_text"
    case markdown
}

public struct AIOutputDocument: Codable, Equatable, Sendable {
    public let format: AIOutputFormat
    public let source: String

    public init(format: AIOutputFormat, source: String) {
        self.format = format
        self.source = Self.normalize(source)
    }

    public var isEmpty: Bool {
        source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalize(_ source: String) -> String {
        source
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard document.format == .markdown else {
            return
        }

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
        case .finderPath, .inputLock, .clipboardQueue, .insert:
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
        Return exactly one JSON object with the fields `format` and `\(field)`, with no code fence or commentary. The `format` value must be \(formats). When using Markdown, use Markdown only for useful structure, use \\(...\\) for inline equations and \\[...\\] for display equations, and never use raw HTML, embedded images, or executable links. When using plain_text, preserve literal punctuation and source markers instead of interpreting them.
        """
    }
}
