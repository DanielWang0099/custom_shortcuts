import Foundation

public enum KeySourceError: LocalizedError, Equatable {
    case missingKey
    case unreadableFile

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            "No OpenAI API key was configured."
        case .unreadableFile:
            "The selected OpenAI API key file could not be read."
        }
    }
}

public enum KeySourceParser {
    public static func parseOpenAIKey(from contents: String) throws -> String {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else {
                continue
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard name == "OPENAI_API_KEY" else {
                continue
            }
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'")
            {
                value.removeFirst()
                value.removeLast()
            }
            guard !value.isEmpty else {
                throw KeySourceError.missingKey
            }
            return value
        }
        throw KeySourceError.missingKey
    }

    public static func loadOpenAIKey(from url: URL) throws -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw KeySourceError.unreadableFile
        }
        return try parseOpenAIKey(from: contents)
    }
}
