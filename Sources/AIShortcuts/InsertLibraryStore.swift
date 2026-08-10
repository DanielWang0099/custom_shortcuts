import AIShortcutsCore
import Darwin
import Foundation

enum InsertLibraryError: LocalizedError {
    case duplicateKey
    case missingEntry
    case invalidEntry
    case reservedKey

    var errorDescription: String? {
        switch self {
        case .duplicateKey:
            "That Insert key already exists."
        case .missingEntry:
            "That Insert entry no longer exists."
        case .invalidEntry:
            "Both the key and value are required."
        case .reservedKey:
            "That name is reserved by a Dynamic insertion."
        }
    }
}

@MainActor
final class InsertLibraryStore {
    private let fileManager: FileManager
    private let fileURL: URL
    private(set) var entries: [InsertEntry]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let directory = root.appendingPathComponent(
            AppConfiguration.bundleIdentifier,
            isDirectory: true
        )
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fileURL = directory.appendingPathComponent("insert-library.json")
        entries = Self.load(from: fileURL)
    }

    @discardableResult
    func add(key rawKey: String, value rawValue: String) throws -> InsertEntry {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else {
            throw InsertLibraryError.invalidEntry
        }
        guard !InsertBuiltIns.conflicts(with: key) else {
            throw InsertLibraryError.reservedKey
        }
        guard !containsKey(key) else {
            throw InsertLibraryError.duplicateKey
        }
        let entry = InsertEntry(key: key, value: value)
        entries.append(entry)
        sortEntries()
        try persist()
        return entry
    }

    @discardableResult
    func update(id: UUID, key rawKey: String, value rawValue: String) throws -> InsertEntry {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else {
            throw InsertLibraryError.invalidEntry
        }
        guard !InsertBuiltIns.conflicts(with: key) else {
            throw InsertLibraryError.reservedKey
        }
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw InsertLibraryError.missingEntry
        }
        let duplicate = entries.contains {
            $0.id != id
                && comparisonKey($0.key) == comparisonKey(key)
        }
        guard !duplicate else {
            throw InsertLibraryError.duplicateKey
        }
        entries[index].key = key
        entries[index].value = value
        entries[index].updatedAt = Date()
        let updated = entries[index]
        sortEntries()
        try persist()
        return updated
    }

    func delete(id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw InsertLibraryError.missingEntry
        }
        entries.remove(at: index)
        try persist()
    }

    private func containsKey(_ key: String) -> Bool {
        let normalized = comparisonKey(key)
        return entries.contains { comparisonKey($0.key) == normalized }
    }

    private func comparisonKey(_ key: String) -> String {
        InsertEntryMatcher.normalized(key).replacingOccurrences(of: " ", with: "")
    }

    private func sortEntries() {
        entries.sort {
            $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: [.atomic])
        _ = chmod(fileURL.path, S_IRUSR | S_IWUSR)
    }

    private static func load(from url: URL) -> [InsertEntry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([InsertEntry].self, from: data)
        else {
            return []
        }
        return decoded.sorted {
            $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }
    }
}
