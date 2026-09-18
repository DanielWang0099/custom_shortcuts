import AppKit
import Foundation

/// A fully materialized pasteboard snapshot. Capture may request data from a
/// lazy source, so the app runs it in a bounded helper process.
public struct ClipboardSnapshot: Codable, Sendable {
    public struct Representation: Codable, Sendable {
        public let type: String
        public let data: Data
    }

    public struct Item: Codable, Sendable {
        public let representations: [Representation]
    }

    public let items: [Item]

    private static let maximumBytes = 50_000_000

    @MainActor
    public static func capture(from pasteboard: NSPasteboard) -> ClipboardSnapshot? {
        let generation = pasteboard.changeCount
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        if pasteboardItems.isEmpty {
            guard (pasteboard.types ?? []).isEmpty else {
                return nil
            }
            return ClipboardSnapshot(items: [])
        }

        var totalBytes = 0
        var capturedItems: [Item] = []
        capturedItems.reserveCapacity(pasteboardItems.count)
        for item in pasteboardItems {
            var representations: [Representation] = []
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    return nil
                }
                totalBytes += data.count
                guard totalBytes <= maximumBytes else {
                    return nil
                }
                representations.append(
                    Representation(type: type.rawValue, data: data)
                )
            }
            guard !representations.isEmpty else {
                return nil
            }
            capturedItems.append(Item(representations: representations))
        }
        guard pasteboard.changeCount == generation else {
            return nil
        }
        return ClipboardSnapshot(items: capturedItems)
    }

    public func encoded() -> Data? {
        try? PropertyListEncoder().encode(self)
    }

    public static func decode(_ data: Data) -> ClipboardSnapshot? {
        try? PropertyListDecoder().decode(Self.self, from: data)
    }

    @MainActor
    @discardableResult
    public func restore(to pasteboard: NSPasteboard) -> Bool {
        let restoredItems = items.map { captured -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for representation in captured.representations {
                item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.type)
                )
            }
            return item
        }
        pasteboard.clearContents()
        guard !restoredItems.isEmpty else {
            return true
        }
        return pasteboard.writeObjects(restoredItems)
    }
}
