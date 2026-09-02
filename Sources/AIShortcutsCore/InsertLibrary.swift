import Foundation

public struct InsertEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var key: String
    public var value: String
    public var updatedAt: Date
    public var isBuiltIn: Bool?
    public var aliases: [String]?

    public init(
        id: UUID = UUID(),
        key: String,
        value: String,
        updatedAt: Date = Date(),
        isBuiltIn: Bool = false,
        aliases: [String] = []
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
        self.isBuiltIn = isBuiltIn ? true : nil
        self.aliases = aliases.isEmpty ? nil : aliases
    }

    public var builtIn: Bool { isBuiltIn == true }

    public var lookupLabels: [String] {
        [key] + (aliases ?? [])
    }

    public var smartLookupLabel: String {
        guard let aliases, !aliases.isEmpty else {
            return key
        }
        return "\(key) (aliases: \(aliases.joined(separator: ", ")))"
    }
}

public enum InsertBuiltIns {
    private static let dateID = UUID(uuidString: "a1a1a1a1-0001-4000-8000-000000000001")!
    private static let timeID = UUID(uuidString: "a1a1a1a1-0002-4000-8000-000000000002")!

    public static func entries(
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [InsertEntry] {
        let date = formatter("yyyy-MM-dd", timeZone: timeZone).string(from: now)
        let time = formatter("HH:mm:ss", timeZone: timeZone).string(from: now)
        return [
            InsertEntry(
                id: dateID,
                key: "Date",
                value: date,
                updatedAt: now,
                isBuiltIn: true
            ),
            InsertEntry(
                id: timeID,
                key: "Time",
                value: time,
                updatedAt: now,
                isBuiltIn: true
            ),
        ]
    }

    public static func conflicts(with key: String) -> Bool {
        let candidate = InsertEntryMatcher.normalized(key)
            .replacingOccurrences(of: " ", with: "")
        guard !candidate.isEmpty else {
            return false
        }
        return entries().contains { entry in
            entry.lookupLabels.contains { label in
                InsertEntryMatcher.normalized(label)
                    .replacingOccurrences(of: " ", with: "") == candidate
            }
        }
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

public enum InsertEntryMatcher {
    public static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .joined(separator: " ")
    }

    public static func exactMatch(
        for query: String,
        in entries: [InsertEntry]
    ) -> InsertEntry? {
        let needle = normalized(query)
        guard !needle.isEmpty else {
            return nil
        }
        let compactNeedle = needle.replacingOccurrences(of: " ", with: "")
        return entries.first { entry in
            entry.lookupLabels.contains {
                normalized($0).replacingOccurrences(of: " ", with: "") == compactNeedle
            }
        }
    }

    public static func uniqueContainedMatch(
        for query: String,
        in entries: [InsertEntry]
    ) -> InsertEntry? {
        let needle = normalized(query)
        guard needle.count >= 2 else {
            return nil
        }
        let matches = entries.filter { entry in
            entry.lookupLabels.contains {
                let candidate = normalized($0)
                return candidate.contains(needle) || needle.contains(candidate)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func filtered(
        by query: String,
        entries: [InsertEntry]
    ) -> [InsertEntry] {
        let needle = normalized(query)
        guard !needle.isEmpty else {
            return entries
        }
        return entries.filter {
            normalized($0.key).contains(needle)
                || normalized($0.value).contains(needle)
                || ($0.aliases ?? []).contains { normalized($0).contains(needle) }
        }
    }
}
