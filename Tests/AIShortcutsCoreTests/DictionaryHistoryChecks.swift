import AIShortcutsCore
import Foundation

private struct DictionaryHistoryCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expectDictionaryHistory(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw DictionaryHistoryCheckFailure(description: message)
    }
}

/// Callable from the core check executable's main entry point.
func dictionaryHistoryChecks() async throws {
    try await MainActor.run {
        try dictionaryHistoryMemoryChecks()
        try dictionaryHistoryPersistenceChecks()
        try dictionaryHistoryMalformedAndWriteErrorChecks()
    }
}

@MainActor
private func dictionaryHistoryMemoryChecks() throws {
    let store = DictionaryHistoryStore(fileURL: nil)
    let firstDate = Date(timeIntervalSince1970: 100)
    let first = try expectDictionaryHistoryItem(
        store.record(
            query: "  hola  ",
            sourceLanguage: "auto",
            detectedSourceLanguage: "es",
            targetLanguage: "en",
            at: firstDate
        ),
        "A nonempty lookup was not recorded."
    )
    try expectDictionaryHistory(
        first.query == "  hola  ",
        "History did not preserve the exact source query whitespace."
    )
    try expectDictionaryHistory(
        first.sourceLanguage == "auto" && first.detectedSourceLanguage == "es",
        "Source language metadata was not normalized or retained."
    )

    _ = store.record(
        query: "你好",
        sourceLanguage: "auto",
        targetLanguage: "en",
        at: Date(timeIntervalSince1970: 200)
    )
    _ = store.record(
        query: "こんにちは",
        sourceLanguage: "ja",
        targetLanguage: "en",
        at: Date(timeIntervalSince1970: 300)
    )
    try expectDictionaryHistory(
        store.items.map(\.query) == ["こんにちは", "你好", "  hola  "],
        "History was not ordered newest-first across Unicode lookups."
    )

    let replacement = try expectDictionaryHistoryItem(
        store.record(
            query: "hola",
            sourceLanguage: "AUTO",
            targetLanguage: "EN",
            at: Date(timeIntervalSince1970: 400)
        ),
        "A duplicate lookup did not return its history item."
    )
    try expectDictionaryHistory(
        replacement.id == first.id
            && replacement.query == "hola"
            && replacement.lookedUpAt == Date(timeIntervalSince1970: 400)
            && store.items.count == 3,
        "A duplicate query created a second history item instead of updating its timestamp."
    )

    _ = store.record(
        query: "hola",
        sourceLanguage: "es",
        targetLanguage: "en",
        at: Date(timeIntervalSince1970: 500)
    )
    _ = store.record(
        query: "hola",
        sourceLanguage: "auto",
        targetLanguage: "es",
        at: Date(timeIntervalSince1970: 600)
    )
    try expectDictionaryHistory(
        store.items.count == 5,
        "Changing source or target language incorrectly deduplicated a lookup."
    )

    let translate = try expectDictionaryHistoryItem(store.record(
        query: "hola", sourceLanguage: "auto", targetLanguage: "en",
        presentationMode: .translate, at: Date(timeIntervalSince1970: 700)
    ), "Translate history was not recorded.")
    try expectDictionaryHistory(
        store.items.count == 6 && translate.presentationMode == .translate
            && translate.id != replacement.id && store.items.first == translate,
        "Dictionary and Translate history were incorrectly deduplicated or lost their mode."
    )

    try expectDictionaryHistory(
        store.record(
            query: " \n\t ",
            sourceLanguage: "auto",
            targetLanguage: "en",
            at: Date()
        ) == nil,
        "A whitespace-only lookup was recorded."
    )
    try expectDictionaryHistory(
        store.record(
            query: "casa",
            sourceLanguage: "es",
            targetLanguage: " ",
            at: Date()
        ) == nil,
        "A lookup with no target language was recorded."
    )

    let removedID = replacement.id
    try expectDictionaryHistory(
        store.remove(id: removedID) && !store.items.contains(where: { $0.id == removedID }),
        "Removing a history item did not update the in-memory list."
    )
    try expectDictionaryHistory(
        !store.remove(id: removedID),
        "Removing an unknown history ID unexpectedly succeeded."
    )
    store.clear()
    try expectDictionaryHistory(store.items.isEmpty, "Clearing history left in-memory items behind.")
    try expectDictionaryHistory(store.storageError == nil, "Memory-only clear reported a storage error.")
}

@MainActor
private func dictionaryHistoryPersistenceChecks() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-history-check-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("history.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstDate = Date(timeIntervalSince1970: 10_000)
    let store = DictionaryHistoryStore(fileURL: fileURL)
    let item = try expectDictionaryHistoryItem(
        store.record(
            query: "  casa  ",
            sourceLanguage: "es",
            detectedSourceLanguage: "es",
            targetLanguage: "en",
            at: firstDate
        ),
        "A disk-backed lookup was not recorded."
    )
    try expectDictionaryHistory(store.storageError == nil, "A successful history write reported an error.")
    try expectDictionaryHistory(FileManager.default.fileExists(atPath: fileURL.path), "History file was not created.")

    let reloaded = DictionaryHistoryStore(fileURL: fileURL)
    try expectDictionaryHistory(
        reloaded.items == [item],
        "Persisted history did not round-trip its Unicode/query metadata and date."
    )

    let modeURL = directory.appendingPathComponent("mode-history.json")
    let modeStore = DictionaryHistoryStore(fileURL: modeURL)
    _ = modeStore.record(query: "casa", sourceLanguage: "es", targetLanguage: "en", presentationMode: .translate)
    try expectDictionaryHistory(DictionaryHistoryStore(fileURL: modeURL).items.first?.presentationMode == .translate,
                                "Translate mode was not persisted across history restart.")

    // Both the early array shape and the versioned shape predate the mode
    // property. They must retain their query/languages as Dictionary entries.
    let legacyItem: [String: Any] = [
        "id": UUID().uuidString, "query": "你好", "sourceLanguage": "auto",
        "detectedSourceLanguage": "zh", "targetLanguage": "en", "lookedUpAt": 1_000,
    ]
    for versioned in [false, true] {
        let legacyURL = directory.appendingPathComponent("legacy-\(versioned).json")
        let object: Any = versioned ? ["version": 1, "items": [legacyItem]] : [legacyItem]
        try JSONSerialization.data(withJSONObject: object).write(to: legacyURL)
        let legacy = DictionaryHistoryStore(fileURL: legacyURL)
        try expectDictionaryHistory(legacy.items.first?.query == "你好"
                                    && legacy.items.first?.presentationMode == .dictionary
                                    && legacy.storageError == nil,
                                    "Legacy history without a mode did not migrate to Dictionary.")
    }

    let preciseFileURL = directory.appendingPathComponent("precise-dates.json")
    let preciseStore = DictionaryHistoryStore(fileURL: preciseFileURL)
    let olderDate = Date(timeIntervalSince1970: 10_100.125)
    let newerDate = Date(timeIntervalSince1970: 10_100.875)
    _ = preciseStore.record(
        query: "older",
        sourceLanguage: "en",
        targetLanguage: "es",
        at: olderDate
    )
    _ = preciseStore.record(
        query: "newer",
        sourceLanguage: "en",
        targetLanguage: "es",
        at: newerDate
    )
    let preciseReloaded = DictionaryHistoryStore(fileURL: preciseFileURL)
    try expectDictionaryHistory(
        preciseReloaded.items.map(\.query) == ["newer", "older"]
            && abs(preciseReloaded.items[0].lookedUpAt.timeIntervalSince1970 - newerDate.timeIntervalSince1970) < 0.000001
            && abs(preciseReloaded.items[1].lookedUpAt.timeIntervalSince1970 - olderDate.timeIntervalSince1970) < 0.000001,
        "Subsecond timestamps lost newest-first ordering or precision after history restart."
    )

    let boundedFileURL = directory.appendingPathComponent("bounded.json")
    let bounded = DictionaryHistoryStore(fileURL: boundedFileURL, maxItems: 2, maxBytes: 900)
    for index in 0..<4 {
        _ = bounded.record(
            query: "查询\(index)",
            sourceLanguage: "zh",
            targetLanguage: "en",
            at: Date(timeIntervalSince1970: 20_000 + Double(index))
        )
    }
    try expectDictionaryHistory(
        bounded.items.count == 2
            && bounded.items.map(\.query) == ["查询3", "查询2"],
        "History did not enforce its bounded newest-first item count."
    )
    let boundedData = try Data(contentsOf: boundedFileURL)
    try expectDictionaryHistory(
        boundedData.count <= 900,
        "History exceeded its configured encoded byte bound."
    )

    let sizingTwoURL = directory.appendingPathComponent("sizing-two.json")
    let sizingThreeURL = directory.appendingPathComponent("sizing-three.json")
    let sizingTwo = DictionaryHistoryStore(fileURL: sizingTwoURL)
    let sizingThree = DictionaryHistoryStore(fileURL: sizingThreeURL)
    for index in 0..<2 {
        _ = sizingTwo.record(
            query: "size\(index)",
            sourceLanguage: "en",
            targetLanguage: "es",
            at: Date(timeIntervalSince1970: 21_000 + Double(index))
        )
    }
    for index in 0..<3 {
        _ = sizingThree.record(
            query: "size\(index)",
            sourceLanguage: "en",
            targetLanguage: "es",
            at: Date(timeIntervalSince1970: 21_000 + Double(index))
        )
    }
    let twoItemSize = try Data(contentsOf: sizingTwoURL).count
    let threeItemSize = try Data(contentsOf: sizingThreeURL).count
    let byteLimit = max(twoItemSize, threeItemSize - 1)
    let byteBoundedURL = directory.appendingPathComponent("byte-bounded.json")
    let byteBounded = DictionaryHistoryStore(
        fileURL: byteBoundedURL,
        maxItems: 100,
        maxBytes: byteLimit
    )
    for index in 0..<3 {
        _ = byteBounded.record(
            query: "size\(index)",
            sourceLanguage: "en",
            targetLanguage: "es",
            at: Date(timeIntervalSince1970: 21_000 + Double(index))
        )
    }
    try expectDictionaryHistory(
        byteBounded.items.count == 2
            && byteBounded.items.map(\.query) == ["size2", "size1"],
        "Byte eviction did not update live items when the count limit was not reached."
    )
    let byteReloaded = DictionaryHistoryStore(
        fileURL: byteBoundedURL,
        maxItems: 100,
        maxBytes: byteLimit
    )
    try expectDictionaryHistory(
        byteReloaded.items == byteBounded.items,
        "Byte-evicted history did not round-trip the same live items after restart."
    )

    let oversizedURL = directory.appendingPathComponent("oversized-record.json")
    let oversizedStore = DictionaryHistoryStore(
        fileURL: oversizedURL,
        maxItems: 100,
        maxBytes: 900
    )
    let retained = try expectDictionaryHistoryItem(
        oversizedStore.record(
            query: "keep",
            sourceLanguage: "en",
            targetLanguage: "es",
            at: Date(timeIntervalSince1970: 22_000)
        ),
        "The baseline history item for oversized-record testing was not saved."
    )
    let oversizedItems = oversizedStore.items
    try expectDictionaryHistory(
        oversizedStore.record(
            query: String(repeating: "x", count: 2_000),
            sourceLanguage: "en",
            targetLanguage: "es",
            at: Date(timeIntervalSince1970: 22_001)
        ) == nil
            && oversizedStore.storageError == .entryTooLarge
            && oversizedStore.items == oversizedItems,
        "An oversized newest record evicted or replaced existing useful history."
    )
    try expectDictionaryHistory(
        DictionaryHistoryStore(
            fileURL: oversizedURL,
            maxItems: 100,
            maxBytes: 900
        ).items == [retained],
        "An oversized record changed the persisted history despite being rejected."
    )

    let removed = reloaded.items[0].id
    try expectDictionaryHistory(
        reloaded.remove(id: removed),
        "A persisted item could not be removed."
    )
    let afterRemoval = DictionaryHistoryStore(fileURL: fileURL)
    try expectDictionaryHistory(afterRemoval.items.isEmpty, "A removed item returned after reload.")

    _ = reloaded.record(
        query: "再见",
        sourceLanguage: "zh",
        targetLanguage: "en",
        at: Date(timeIntervalSince1970: 11_000)
    )
    reloaded.clear()
    try expectDictionaryHistory(
        !FileManager.default.fileExists(atPath: fileURL.path) && reloaded.items.isEmpty,
        "Clearing disk-backed history did not remove the persisted file."
    )
}

@MainActor
private func dictionaryHistoryMalformedAndWriteErrorChecks() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-history-errors-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let malformedURL = directory.appendingPathComponent("malformed.json")
    try Data("{ definitely not history".utf8).write(to: malformedURL)
    let malformed = DictionaryHistoryStore(fileURL: malformedURL)
    try expectDictionaryHistory(
        malformed.items.isEmpty && malformed.storageError == .malformedData,
        "Malformed history did not fail closed with an actionable storage error."
    )
    _ = malformed.record(
        query: "恢复",
        sourceLanguage: "zh",
        targetLanguage: "en",
        at: Date(timeIntervalSince1970: 12_000)
    )
    try expectDictionaryHistory(
        malformed.storageError == nil
            && DictionaryHistoryStore(fileURL: malformedURL).items.count == 1,
        "A valid write could not recover from malformed history."
    )

    let directoryAsFile = directory.appendingPathComponent("directory-target", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryAsFile, withIntermediateDirectories: true)
    let writeFailure = DictionaryHistoryStore(fileURL: directoryAsFile)
    let item = writeFailure.record(
        query: "食べる",
        sourceLanguage: "ja",
        targetLanguage: "en",
        at: Date(timeIntervalSince1970: 13_000)
    )
    try expectDictionaryHistory(
        item != nil && writeFailure.items.count == 1 && writeFailure.storageError != nil,
        "A history write failure did not preserve in-memory state or report an error."
    )

    let oversizedFileURL = directory.appendingPathComponent("oversized-file.json")
    let fileLimit = 900
    try Data(repeating: 0, count: fileLimit + 1).write(to: oversizedFileURL)
    let oversizedFile = DictionaryHistoryStore(
        fileURL: oversizedFileURL,
        maxBytes: fileLimit
    )
    try expectDictionaryHistory(
        oversizedFile.items.isEmpty
            && oversizedFile.storageError == .fileTooLarge(
                actualBytes: fileLimit + 1,
                maxBytes: fileLimit
            ),
        "An oversized history file was decoded instead of being rejected early."
    )
}

private func expectDictionaryHistoryItem(
    _ item: DictionaryHistoryItem?,
    _ message: String
) throws -> DictionaryHistoryItem {
    guard let item else {
        throw DictionaryHistoryCheckFailure(description: message)
    }
    return item
}
