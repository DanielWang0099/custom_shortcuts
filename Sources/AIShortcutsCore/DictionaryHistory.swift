import Foundation

/// A recent dictionary lookup kept for quick access from the dictionary panel.
///
/// `query` is intentionally stored exactly as it was supplied. The store uses
/// a trimmed, Unicode-normalized form only for validation and duplicate
/// detection, so a history item can reproduce the user's original query.
public struct DictionaryHistoryItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let query: String
    public let sourceLanguage: String
    public let detectedSourceLanguage: String?
    public let targetLanguage: String
    public let lookedUpAt: Date

    public init(
        id: UUID = UUID(),
        query: String,
        sourceLanguage: String,
        detectedSourceLanguage: String? = nil,
        targetLanguage: String,
        lookedUpAt: Date = Date()
    ) {
        self.id = id
        self.query = query
        self.sourceLanguage = sourceLanguage
        self.detectedSourceLanguage = detectedSourceLanguage
        self.targetLanguage = targetLanguage
        self.lookedUpAt = lookedUpAt
    }
}

/// Errors which can be surfaced by the history UI without making persistence
/// failures fatal to an otherwise useful in-memory history list.
public enum DictionaryHistoryStorageError: Error, Equatable, LocalizedError, Sendable {
    case readFailed(String)
    case malformedData
    case writeFailed(String)
    case deleteFailed(String)
    case entryTooLarge
    case fileTooLarge(actualBytes: Int, maxBytes: Int)

    public var errorDescription: String? {
        switch self {
        case let .readFailed(detail):
            "Dictionary history could not be read: \(detail)"
        case .malformedData:
            "Dictionary history was malformed and was ignored."
        case let .writeFailed(detail):
            "Dictionary history could not be saved: \(detail)"
        case let .deleteFailed(detail):
            "Dictionary history could not be cleared: \(detail)"
        case .entryTooLarge:
            "This dictionary lookup is too large to save in history."
        case let .fileTooLarge(actualBytes, maxBytes):
            "Dictionary history is \(actualBytes) bytes, over the \(maxBytes)-byte limit."
        }
    }
}

/// A small, synchronous, main-actor history store for dictionary lookups.
///
/// The default initializer location is in its own Application Support
/// subdirectory. Pass `fileURL: nil` for an in-memory store, which is useful
/// for previews and tests and prevents fixture lookups from touching the
/// user's history.
@MainActor
public final class DictionaryHistoryStore {
    public static let defaultFileURL: URL = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("AIShortcuts", isDirectory: true)
            .appendingPathComponent("Dictionary", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }()

    public let fileURL: URL?
    public let maxItems: Int
    public let maxBytes: Int
    public private(set) var items: [DictionaryHistoryItem]
    public private(set) var storageError: DictionaryHistoryStorageError?

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static let defaultMaxItems = 100
    private static let defaultMaxBytes = 1_048_576

    private struct PersistedHistory: Codable {
        let version: Int
        let items: [DictionaryHistoryItem]

        init(items: [DictionaryHistoryItem]) {
            self.version = 1
            self.items = items
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            items = try container.decode([DictionaryHistoryItem].self, forKey: .items)
        }
    }

    public init(
        fileURL: URL? = DictionaryHistoryStore.defaultFileURL,
        maxItems: Int = 100,
        maxBytes: Int = 1_048_576,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.maxItems = max(1, min(maxItems, Self.defaultMaxItems))
        self.maxBytes = max(1, min(maxBytes, Self.defaultMaxBytes))
        self.fileManager = fileManager

        let configuredEncoder = JSONEncoder()
        // Numeric seconds preserve the subsecond lookup order that ISO8601
        // encoding on older Foundation releases can silently discard.
        configuredEncoder.dateEncodingStrategy = .secondsSince1970
        configuredEncoder.outputFormatting = [.sortedKeys]
        self.encoder = configuredEncoder

        let configuredDecoder = JSONDecoder()
        // Read both the current numeric representation and history files
        // written by the earlier ISO8601 representation.
        configuredDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let string = try container.decode(String.self)
            guard let date = ISO8601DateFormatter().date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid dictionary history date."
                )
            }
            return date
        }
        self.decoder = configuredDecoder

        self.items = []
        self.storageError = nil
        load()
    }

    /// Records a meaningful lookup and returns the resulting item. Empty or
    /// whitespace-only queries, targets, and individually oversized records
    /// are ignored and return `nil`.
    @discardableResult
    public func record(
        query: String,
        sourceLanguage: String,
        detectedSourceLanguage: String? = nil,
        targetLanguage: String,
        at date: Date = Date()
    ) -> DictionaryHistoryItem? {
        let queryKey = Self.normalizedQuery(query)
        guard !queryKey.isEmpty,
              let target = Self.normalizedLanguage(targetLanguage)
        else {
            return nil
        }

        let source = Self.normalizedLanguage(sourceLanguage) ?? "auto"
        let detected = Self.normalizedLanguage(detectedSourceLanguage)
        let key = Self.deduplicationKey(
            query: queryKey,
            sourceLanguage: source,
            targetLanguage: target
        )

        let result: DictionaryHistoryItem
        var proposedItems = items
        if let existingIndex = items.firstIndex(where: {
            Self.deduplicationKey(for: $0) == key
        }) {
            let existing = items[existingIndex]
            result = DictionaryHistoryItem(
                id: existing.id,
                query: query,
                sourceLanguage: source,
                detectedSourceLanguage: detected,
                targetLanguage: target,
                lookedUpAt: date
            )
            proposedItems[existingIndex] = result
        } else {
            result = DictionaryHistoryItem(
                query: query,
                sourceLanguage: source,
                detectedSourceLanguage: detected,
                targetLanguage: target,
                lookedUpAt: date
            )
            proposedItems.append(result)
        }

        let candidateItems = normalizedItems(proposedItems)
        do {
            // Check the new/updated record by itself first. If it cannot fit,
            // retain the existing list instead of evicting useful history.
            guard try persistencePlan(for: [result]) != nil else {
                storageError = .entryTooLarge
                return nil
            }
            guard let plan = try persistencePlan(for: candidateItems) else {
                storageError = .entryTooLarge
                return nil
            }
            items = plan.items
            write(plan: plan)
            return items.contains(where: { $0.id == result.id }) ? result : nil
        } catch {
            storageError = .writeFailed(error.localizedDescription)
            return nil
        }
    }

    /// Removes one lookup. The in-memory mutation still takes effect when the
    /// file cannot be written; `storageError` reports that persistence issue.
    @discardableResult
    public func remove(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return false
        }
        items.remove(at: index)
        persistCurrentItems()
        return true
    }

    /// Removes every lookup and deletes the history file when one exists.
    public func clear() {
        items.removeAll(keepingCapacity: true)
        guard let fileURL else {
            storageError = nil
            return
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            storageError = nil
            return
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            storageError = .deleteFailed("The history location is a directory.")
            return
        }

        do {
            try fileManager.removeItem(at: fileURL)
            storageError = nil
        } catch {
            storageError = .deleteFailed(error.localizedDescription)
        }
    }

    private func load() {
        guard let fileURL else {
            return
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        let data: Data
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            if let size = attributes[.size] as? NSNumber,
               size.int64Value > Int64(maxBytes)
            {
                storageError = .fileTooLarge(
                    actualBytes: Int(clamping: size.int64Value),
                    maxBytes: maxBytes
                )
                items = []
                return
            }
            data = try Data(contentsOf: fileURL)
        } catch {
            storageError = .readFailed(error.localizedDescription)
            return
        }

        do {
            let decodedItems: [DictionaryHistoryItem]
            if let persisted = try? decoder.decode(PersistedHistory.self, from: data) {
                decodedItems = persisted.items
            } else {
                // Accept the early, unversioned array shape so an interrupted
                // migration does not discard otherwise valid user history.
                decodedItems = try decoder.decode([DictionaryHistoryItem].self, from: data)
            }
            items = normalizedItems(decodedItems)
            storageError = nil
        } catch {
            items = []
            storageError = .malformedData
        }
    }

    private struct PersistencePlan {
        let items: [DictionaryHistoryItem]
        let data: Data
    }

    private func persistCurrentItems() {
        do {
            guard let plan = try persistencePlan(for: items) else {
                storageError = .entryTooLarge
                return
            }
            items = plan.items
            write(plan: plan)
        } catch {
            storageError = .writeFailed(error.localizedDescription)
        }
    }

    private func write(plan: PersistencePlan) {
        guard let fileURL else {
            storageError = nil
            return
        }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try plan.data.write(to: fileURL, options: [.atomic])
            // `.atomic` replaces the destination, so apply private permissions
            // after each successful replacement.
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            storageError = nil
        } catch {
            storageError = .writeFailed(error.localizedDescription)
        }
    }

    private func persistencePlan(
        for sourceItems: [DictionaryHistoryItem]
    ) throws -> PersistencePlan? {
        var candidateItems = Array(sourceItems.prefix(maxItems))
        while true {
            let data = try encoder.encode(PersistedHistory(items: candidateItems))
            if data.count <= maxBytes {
                return PersistencePlan(items: candidateItems, data: data)
            }
            guard candidateItems.count > 1 else {
                return nil
            }
            // Items are newest-first, so remove the oldest item first. The
            // returned plan is committed to memory as well as to disk.
            candidateItems.removeLast()
        }
    }

    private func normalizedItems(_ sourceItems: [DictionaryHistoryItem]) -> [DictionaryHistoryItem] {
        var deduplicated: [String: DictionaryHistoryItem] = [:]
        for item in sourceItems {
            guard let normalized = normalizedItem(item) else {
                continue
            }
            let key = Self.deduplicationKey(for: normalized)
            if let existing = deduplicated[key], existing.lookedUpAt > normalized.lookedUpAt {
                continue
            }
            deduplicated[key] = normalized
        }

        return deduplicated.values
            .sorted {
                if $0.lookedUpAt != $1.lookedUpAt {
                    return $0.lookedUpAt > $1.lookedUpAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(maxItems)
            .map { $0 }
    }

    private func normalizedItem(_ item: DictionaryHistoryItem) -> DictionaryHistoryItem? {
        let queryKey = Self.normalizedQuery(item.query)
        guard !queryKey.isEmpty,
              let target = Self.normalizedLanguage(item.targetLanguage)
        else {
            return nil
        }
        return DictionaryHistoryItem(
            id: item.id,
            query: item.query,
            sourceLanguage: Self.normalizedLanguage(item.sourceLanguage) ?? "auto",
            detectedSourceLanguage: Self.normalizedLanguage(item.detectedSourceLanguage),
            targetLanguage: target,
            lookedUpAt: item.lookedUpAt
        )
    }

    private static func normalizedQuery(_ query: String) -> String {
        query
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedLanguage(_ language: String?) -> String? {
        guard let language else {
            return nil
        }
        let normalized = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func deduplicationKey(for item: DictionaryHistoryItem) -> String {
        deduplicationKey(
            query: normalizedQuery(item.query),
            sourceLanguage: normalizedLanguage(item.sourceLanguage) ?? "auto",
            targetLanguage: normalizedLanguage(item.targetLanguage) ?? ""
        )
    }

    private static func deduplicationKey(
        query: String,
        sourceLanguage: String,
        targetLanguage: String
    ) -> String {
        // Length prefixes avoid collisions if a query contains separators.
        "\(query.utf8.count):\(query)|\(sourceLanguage)|\(targetLanguage)"
    }
}
