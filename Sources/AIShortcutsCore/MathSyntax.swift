import Foundation

public struct MathSpan: Equatable, Sendable {
    public let range: NSRange
    public let source: String
    public let expression: String
    public let isDisplay: Bool

    public init(
        range: NSRange,
        source: String,
        expression: String,
        isDisplay: Bool
    ) {
        self.range = range
        self.source = source
        self.expression = expression
        self.isDisplay = isDisplay
    }
}

public enum MathSyntax {
    public static func mathSpans(in source: String) -> [MathSpan] {
        var spans: [MathSpan] = []
        var index = source.startIndex
        var isLineStart = true
        var inFence = false
        var inInlineCode = false

        while index < source.endIndex {
            let character = source[index]
            if character == "\n" {
                isLineStart = true
                index = source.index(after: index)
                continue
            }

            if isLineStart {
                let lineStart = source[index...]
                if lineStart.hasPrefix("```") || lineStart.hasPrefix("~~~") {
                    inFence.toggle()
                    inInlineCode = false
                    index = endOfLine(in: source, from: index)
                    isLineStart = false
                    continue
                }
                isLineStart = false
            }

            if inFence {
                index = source.index(after: index)
                continue
            }

            if character == "`" {
                inInlineCode.toggle()
                index = source.index(after: index)
                continue
            }
            if inInlineCode {
                index = source.index(after: index)
                continue
            }

            let candidate: (opening: String, closing: String, display: Bool)?
            if source[index...].hasPrefix("\\[") {
                candidate = ("\\[", "\\]", true)
            } else if source[index...].hasPrefix("\\(") {
                candidate = ("\\(", "\\)", false)
            } else if source[index...].hasPrefix("$$") {
                candidate = ("$$", "$$", true)
            } else if character == "$",
                      !isEscaped(source, at: index),
                      nextCharacter(in: source, after: index) != "$",
                      nextCharacter(in: source, after: index)?.isWhitespace != true,
                      nextCharacter(in: source, after: index)?.isNumber != true
            {
                candidate = ("$", "$", false)
            } else {
                candidate = nil
            }

            guard let candidate,
                  let closingRange = source.range(
                      of: candidate.closing,
                      range: source.index(after: index)..<source.endIndex
                  )
            else {
                index = source.index(after: index)
                continue
            }

            if candidate.opening == "$"
                && (previousCharacter(in: source, before: closingRange.lowerBound) == "$"
                    || nextCharacter(in: source, after: closingRange.lowerBound) == "$")
            {
                index = source.index(after: index)
                continue
            }

            let expressionStart = source.index(index, offsetBy: candidate.opening.count)
            let expression = String(source[expressionStart..<closingRange.lowerBound])
            guard isValidCandidate(
                expression,
                delimiter: candidate.opening,
                display: candidate.display
            ) else {
                index = source.index(after: index)
                continue
            }

            let end = closingRange.upperBound
            let rawSource = String(source[index..<end])
            spans.append(
                MathSpan(
                    range: NSRange(index..<end, in: source),
                    source: rawSource,
                    expression: expression,
                    isDisplay: candidate.display
                )
            )
            index = end
        }

        return spans
    }

    /// Returns true when a likely math opener outside code has no matching
    /// closer. The renderer uses this to keep malformed source styled instead
    /// of accidentally treating `\(` or `\[` as a Markdown escape.
    public static func hasUnclosedMathDelimiter(in source: String) -> Bool {
        var index = source.startIndex
        var isLineStart = true
        var inFence = false
        var inInlineCode = false

        while index < source.endIndex {
            let character = source[index]
            if character == "\n" {
                isLineStart = true
                index = source.index(after: index)
                continue
            }
            if isLineStart {
                let lineStart = source[index...]
                if lineStart.hasPrefix("```") || lineStart.hasPrefix("~~~") {
                    inFence.toggle()
                    inInlineCode = false
                    index = endOfLine(in: source, from: index)
                    isLineStart = false
                    continue
                }
                isLineStart = false
            }
            if inFence {
                index = source.index(after: index)
                continue
            }
            if character == "`" {
                inInlineCode.toggle()
                index = source.index(after: index)
                continue
            }
            if inInlineCode {
                index = source.index(after: index)
                continue
            }

            if source[index...].hasPrefix("\\(") {
                guard source.range(
                    of: "\\)",
                    range: source.index(after: index)..<source.endIndex
                ) != nil else {
                    return true
                }
                index = source.index(index, offsetBy: 2)
                continue
            }
            if source[index...].hasPrefix("\\[") {
                guard source.range(
                    of: "\\]",
                    range: source.index(after: index)..<source.endIndex
                ) != nil else {
                    return true
                }
                index = source.index(index, offsetBy: 2)
                continue
            }
            if source[index...].hasPrefix("$$") {
                guard source.range(
                    of: "$$",
                    range: source.index(index, offsetBy: 2)..<source.endIndex
                ) != nil else {
                    return true
                }
                index = source.index(index, offsetBy: 2)
                continue
            }
            if character == "$",
               !isEscaped(source, at: index),
               nextCharacter(in: source, after: index) != "$",
               nextCharacter(in: source, after: index)?.isWhitespace != true,
               nextCharacter(in: source, after: index)?.isNumber != true
            {
                let lineEnd = endOfLine(in: source, from: index)
                guard source.range(
                    of: "$",
                    range: source.index(after: index)..<lineEnd
                ) != nil else {
                    return true
                }
            }
            index = source.index(after: index)
        }
        return false
    }

    public static func isSupportedExpression(_ expression: String) -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\n"),
              !trimmed.contains("&"),
              !trimmed.contains("\\begin"),
              !trimmed.contains("\\end")
        else {
            return false
        }

        var braceDepth = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            switch character {
            case "{":
                braceDepth += 1
            case "}":
                braceDepth -= 1
                guard braceDepth >= 0 else {
                    return false
                }
            case "\\":
                let commandStart = trimmed.index(after: index)
                guard commandStart < trimmed.endIndex else {
                    return false
                }
                var commandEnd = commandStart
                while commandEnd < trimmed.endIndex,
                      trimmed[commandEnd].isLetter
                {
                    commandEnd = trimmed.index(after: commandEnd)
                }
                if commandEnd == commandStart {
                    let symbol = trimmed[commandStart]
                    guard ",;!:_{}[]()^\\ ".contains(symbol) else {
                        return false
                    }
                    index = commandStart
                } else {
                    let command = String(trimmed[commandStart..<commandEnd])
                    guard supportedCommands.contains(command) else {
                        return false
                    }
                    index = trimmed.index(before: commandEnd)
                }
            default:
                break
            }
            index = trimmed.index(after: index)
        }
        return braceDepth == 0
    }

    private static let supportedCommands: Set<String> = [
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
        "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma",
        "tau", "upsilon", "phi", "chi", "psi", "omega", "Gamma", "Delta",
        "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi", "Omega",
        "frac", "sqrt", "sum", "prod", "int", "oint", "times", "cdot", "pm",
        "mp", "le", "leq", "ge", "geq", "neq", "approx", "sim", "equiv", "infty",
        "partial", "nabla", "rightarrow", "leftarrow", "Rightarrow", "Leftarrow",
        "to", "in", "notin", "subset", "subseteq", "cup", "cap", "forall", "exists",
        "sin", "cos", "tan", "cot", "sec", "csc", "log", "ln", "exp", "lim",
        "left", "right",
    ]

    private static func isValidCandidate(
        _ expression: String,
        delimiter: String,
        display: Bool
    ) -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if delimiter == "$" {
            guard !trimmed.hasPrefix(".") else {
                return false
            }
            guard !trimmed.contains("\n"), !trimmed.hasPrefix(" "), !trimmed.hasSuffix(" ") else {
                return false
            }
        }
        if display {
            return !trimmed.contains("\r")
        }
        return true
    }

    private static func endOfLine(in source: String, from start: String.Index) -> String.Index {
        source.range(of: "\n", range: start..<source.endIndex)?.lowerBound
            ?? source.endIndex
    }

    private static func nextCharacter(
        in source: String,
        after index: String.Index
    ) -> Character? {
        let next = source.index(after: index)
        guard next < source.endIndex else {
            return nil
        }
        return source[next]
    }

    private static func previousCharacter(
        in source: String,
        before index: String.Index
    ) -> Character? {
        guard index > source.startIndex else {
            return nil
        }
        return source[source.index(before: index)]
    }

    private static func isEscaped(_ source: String, at index: String.Index) -> Bool {
        var slashCount = 0
        var cursor = index
        while cursor > source.startIndex {
            cursor = source.index(before: cursor)
            guard source[cursor] == "\\" else {
                break
            }
            slashCount += 1
        }
        return slashCount.isMultiple(of: 2) == false
    }
}
