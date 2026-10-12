import AIShortcutsCore
import Foundation

private struct DictionaryCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expectDictionary(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw DictionaryCheckFailure(description: message)
    }
}

private final class DictionaryFixtureTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let response: @Sendable (URLRequest) -> (Data, HTTPURLResponse)
    private var requestCountStorage = 0
    private var requestURLsStorage: [URL] = []

    init(response: @escaping @Sendable (URLRequest) -> (Data, HTTPURLResponse)) {
        self.response = response
    }

    var requestCount: Int {
        lock.withLock { requestCountStorage }
    }

    var requestURLs: [URL] {
        lock.withLock { requestURLsStorage }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            requestCountStorage += 1
            if let url = request.url {
                requestURLsStorage.append(url)
            }
        }
        let result = response(request)
        return (result.0, result.1)
    }
}

private final class CancellableDictionaryFixtureTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Data
    private var requestCountStorage = 0
    private var cancellationCountStorage = 0

    init(result: Data) {
        self.result = result
    }

    var requestCount: Int {
        lock.withLock { requestCountStorage }
    }

    var cancellationCount: Int {
        lock.withLock { cancellationCountStorage }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            requestCountStorage += 1
        }
        do {
            // Long enough that the caller must cancel the shared task; the
            // transport's sleep is cancellation-aware like URLSession.
            try await Task.sleep(for: .seconds(30))
        } catch {
            lock.withLock {
                cancellationCountStorage += 1
            }
            throw error
        }
        let response = dictionaryHTTPResponse(request.url!, statusCode: 200)
        return (result, response)
    }
}

/// Callable from the core check executable's main entry point.
func dictionaryChecks() async throws {
    do {
        try await dictionaryFixtureParsingChecks()
    } catch {
        throw DictionaryCheckFailure(description: "fixture parsing: \(error)")
    }
    do {
        try dictionaryReadingDerivationChecks()
    } catch {
        throw DictionaryCheckFailure(description: "readings: \(error)")
    }
    do {
        try await dictionaryURLAndCacheChecks()
    } catch {
        throw DictionaryCheckFailure(description: "URL/cache: \(error)")
    }
    do {
        try await dictionaryChineseScriptVariantChecks()
    } catch {
        throw DictionaryCheckFailure(description: "Chinese script variants: \(error)")
    }
    do {
        try await dictionaryCancellationChecks()
    } catch {
        throw DictionaryCheckFailure(description: "cancellation: \(error)")
    }
    do {
        try await dictionaryHTTPErrorChecks()
    } catch {
        throw DictionaryCheckFailure(description: "HTTP errors: \(error)")
    }
    do {
        try await dictionaryTypedAIChecks()
    } catch {
        throw DictionaryCheckFailure(description: "typed AI: \(error)")
    }
}

private func dictionaryFixtureParsingChecks() async throws {
    let fixtureLanguages: [(DictionaryLanguage, String, String, String)] = [
        (.en, "hello", "English", "hello"),
        (.es, "hola", "Spanish", "hola"),
        (.zh, "你好", "Chinese", "你好"),
        (.ja, "こんにちは", "Japanese", "こんにちは"),
    ]
    let transport = DictionaryFixtureTransport { request in
        let pathWord = request.url?.path.split(separator: "/").last.map(String.init) ?? "word"
        let word = pathWord.removingPercentEncoding ?? pathWord
        let code = request.url?.path.split(separator: "/").dropLast().last.map(String.init) ?? "und"
        let payload = dictionaryFixtureJSON(
            word: word,
            code: code,
            languageName: code == "es" ? "Spanish" : code == "zh" ? "Chinese" : code == "ja" ? "Japanese" : "English"
        )
        return (payload, dictionaryHTTPResponse(request.url!, statusCode: 200))
    }
    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let service = DictionaryLookupService(
        transport: transport,
        cacheDirectoryURL: cacheDirectory,
        maxCacheEntries: 16
    )

    for (language, word, languageName, expectedHeadword) in fixtureLanguages {
        let result = try await service.lookup(language: language, word: word)
        try expectDictionary(result.word == expectedHeadword, "Dictionary word did not survive decoding for \(language.rawValue).")
        let entry = try expectDictionaryEntry(result.entries.first, "Missing entry for \(language.rawValue).")
        try expectDictionary(entry.language == language, "Entry language was not decoded for \(language.rawValue).")
        try expectDictionary(entry.languageName == languageName, "Entry language name was not decoded for \(language.rawValue).")
        try expectDictionary(entry.headword == expectedHeadword, "Entry headword was not inherited from the response word.")
        try expectDictionary(entry.partOfSpeech == "noun", "Part of speech was not decoded.")
        try expectDictionary(entry.pronunciation == "/fixture/", "Pronunciation was not decoded.")
        try expectDictionary(entry.readings.isEmpty, "IPA pronunciations must not be duplicated as script readings.")
        try expectDictionary(entry.senses.first?.examples == ["A fixture example."], "Sense examples were not decoded.")
        try expectDictionary(
            entry.senses.first?.translations.first?.word == "gloss"
                && entry.senses.first?.translations.first?.definition == "English gloss",
            "Sense translations were not decoded."
        )
        try expectDictionary(result.source?.licenseName == "CC BY-SA", "Top-level attribution license was not decoded.")
        try expectDictionary(entry.attribution?.licenseName == "CC BY-SA", "Top-level attribution was not propagated to entries.")
    }
    try expectDictionary(transport.requestCount == fixtureLanguages.count, "Fixture parsing performed an unexpected number of requests.")
}

private func dictionaryReadingDerivationChecks() throws {
    let japaneseFixture = Data(
        #"""
        {
          "word": "食べる",
          "entries": [{
            "language": {"code": "ja", "name": "Japanese"},
            "partOfSpeech": "verb",
            "pronunciations": [{"type": "ipa", "text": "[ta̠be̞ɾɯ̟]", "tags": []}],
            "forms": [
              {"word": "食べる transitive ichidan", "tags": ["canonical"]},
              {"word": "taberu", "tags": ["romanization"]},
              {"word": "たべる", "tags": ["kana"]},
              {"word": "たべる", "tags": ["terminative"]},
              {"word": "たべる", "tags": ["attributive"]},
              {"word": "たべた", "tags": ["kana", "past"]}
            ],
            "senses": [{"definition": "to eat", "tags": [], "examples": [], "subsenses": [], "translations": []}]
          }]
        }
        """#.utf8
    )
    let japaneseResult = try JSONDecoder().decode(DictionaryLookupResult.self, from: japaneseFixture)
    let japaneseEntry = try expectDictionaryEntry(japaneseResult.entries.first, "Japanese reading fixture did not decode.")
    try expectDictionary(
        japaneseEntry.readings == ["たべる"],
        "Japanese kana derivation accepted an inflected form or lost the lemma reading."
    )
    try expectDictionary(
        japaneseEntry.forms.count == 6 && japaneseEntry.forms[1].word == "taberu",
        "Japanese reading derivation altered the original forms."
    )
    try expectDictionary(
        japaneseEntry.pronunciation == "[ta̠be̞ɾɯ̟]",
        "Japanese IPA pronunciation was not preserved separately from kana."
    )

    let chineseFixture = Data(
        #"""
        {
          "word": "吃",
          "entries": [{
            "language": {"code": "zh", "name": "Chinese"},
            "partOfSpeech": "verb",
            "pronunciations": [
              {"type": "ipa", "text": "[tʂʰɤ]", "tags": []},
              {"type": "pinyin", "text": "chī", "tags": []}
            ],
            "forms": [
              {"word": "吃", "tags": ["canonical"]},
              {"word": "chi1", "tags": ["pinyin"]}
            ],
            "senses": [{"definition": "to eat", "tags": [], "examples": [], "subsenses": [], "translations": []}]
          }]
        }
        """#.utf8
    )
    let chineseResult = try JSONDecoder().decode(DictionaryLookupResult.self, from: chineseFixture)
    let chineseEntry = try expectDictionaryEntry(chineseResult.entries.first, "Chinese reading fixture did not decode.")
    try expectDictionary(
        chineseEntry.readings == ["chī", "chi1"],
        "Chinese pinyin was not preferred from explicit pronunciation/form metadata."
    )
    try expectDictionary(
        chineseEntry.pronunciation == "[tʂʰɤ]",
        "Chinese IPA pronunciation was overwritten by pinyin."
    )
}

private func dictionaryURLAndCacheChecks() async throws {
    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-cache-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let transport = DictionaryFixtureTransport { request in
        let pathWord = request.url?.path.split(separator: "/").last.map(String.init) ?? "word"
        let word = pathWord.removingPercentEncoding ?? pathWord
        let payload = dictionaryFixtureJSON(word: word, code: "en", languageName: "English")
        return (payload, dictionaryHTTPResponse(request.url!, statusCode: 200))
    }
    let service = DictionaryLookupService(
        transport: transport,
        cacheDirectoryURL: cacheDirectory,
        maxCacheEntries: 1,
        maxCacheBytes: 8 * 1024
    )

    let request = try await service.makeRequest(language: .en, word: "ice cream")
    try expectDictionary(request.value(forHTTPHeaderField: "User-Agent")?.isEmpty == false, "Dictionary requests must send an explicit User-Agent.")
    try expectDictionary(request.url?.absoluteString.contains("translations=true") == true, "Dictionary requests must request translations.")
    try expectDictionary(request.url?.absoluteString.contains("ice%20cream") == true, "Dictionary word path was not percent encoded.")
    let slashRequest = try await service.makeRequest(language: .en, word: "a/b")
    try expectDictionary(
        slashRequest.url?.absoluteString.contains("a%2Fb") == true,
        "A slash-containing dictionary word must stay in one encoded path segment."
    )

    _ = try await service.lookup(language: .en, word: "hello")
    _ = try await service.lookup(language: .en, word: "hello")
    try expectDictionary(transport.requestCount == 1, "A successful raw dictionary response was not read from cache.")
    let cachedResult = await service.cachedLookup(language: .en, word: "hello")
    try expectDictionary(
        cachedResult?.word == "hello",
        "The cache-only dictionary read did not return the stored entry."
    )
    try expectDictionary(
        DictionaryLookupService.cacheKey(language: .en, word: "hello")
            != DictionaryLookupService.cacheKey(language: .en, word: "Hello"),
        "Dictionary cache keys must preserve case distinctions."
    )
    _ = try await service.lookup(language: .en, word: "Hello")
    try expectDictionary(transport.requestCount == 2, "Case-distinct dictionary words incorrectly shared cache entries.")
    let cacheFiles = try FileManager.default.contentsOfDirectory(
        at: cacheDirectory,
        includingPropertiesForKeys: nil
    )
    try expectDictionary(cacheFiles.count <= 1, "Dictionary cache exceeded its entry bound.")

    let concurrentTransport = DictionaryFixtureTransport { request in
        let pathWord = request.url?.path.split(separator: "/").last.map(String.init) ?? "word"
        let word = pathWord.removingPercentEncoding ?? pathWord
        let payload = dictionaryFixtureJSON(word: word, code: "en", languageName: "English")
        return (payload, dictionaryHTTPResponse(request.url!, statusCode: 200))
    }
    let concurrentService = DictionaryLookupService(
        transport: concurrentTransport,
        cacheDirectoryURL: cacheDirectory.appendingPathComponent("concurrent", isDirectory: true)
    )
    async let first = concurrentService.lookup(language: .en, word: "dedup", useCache: false)
    async let second = concurrentService.lookup(language: .en, word: "dedup", useCache: false)
    _ = try await (first, second)
    try expectDictionary(concurrentTransport.requestCount == 1, "Concurrent dictionary lookups were not deduplicated.")
}

private func dictionaryChineseScriptVariantChecks() async throws {
    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-script-variant-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }

    let simplifiedWord = "参考"
    let traditionalWord = "參考"
    let attributionURL = "https://fixture.example/variant/參考"
    let transport = DictionaryFixtureTransport { request in
        let word = dictionaryRequestWord(request)
        let payload: Data
        if word == simplifiedWord {
            payload = dictionaryEmptyFixtureJSON(word: word, sourceURL: "https://fixture.example/variant/参考")
        } else if word == traditionalWord {
            payload = dictionaryVariantFixtureJSON(
                word: word,
                reading: "cān kǎo",
                sourceURL: attributionURL
            )
        } else {
            payload = dictionaryEmptyFixtureJSON(word: word, sourceURL: "https://fixture.example/variant/empty")
        }
        return (payload, dictionaryHTTPResponse(request.url!, statusCode: 200))
    }
    let service = DictionaryLookupService(
        transport: transport,
        cacheDirectoryURL: cacheDirectory
    )

    let aliased = try await service.lookup(language: .zh, word: simplifiedWord)
    try expectDictionary(aliased.word == simplifiedWord, "Script fallback changed the submitted result word.")
    try expectDictionary(aliased.entries.first?.headword == traditionalWord,
                         "Script fallback lost the provider's Traditional headword.")
    try expectDictionary(aliased.entries.first?.readings == ["cān kǎo"],
                         "Script fallback lost provider readings.")
    let expectedAttributionURL = URL(string: attributionURL)
    try expectDictionary(aliased.source?.sourceURL == expectedAttributionURL,
                         "Script fallback lost top-level attribution.")
    try expectDictionary(aliased.entries.first?.attribution?.sourceURL == expectedAttributionURL,
                         "Script fallback lost entry attribution.")
    try expectDictionary(transport.requestCount == 2,
                         "Simplified miss did not make exactly one Traditional variant request.")
    try expectDictionary(
        transport.requestURLs.map(dictionaryRequestWord) == [simplifiedWord, traditionalWord],
        "Script fallback requested the wrong variant order."
    )

    _ = try await service.lookup(language: .zh, word: simplifiedWord)
    try expectDictionary(transport.requestCount == 2,
                         "A successful script alias was not read from the original in-memory cache key.")

    let diskTransport = DictionaryFixtureTransport { request in
        (dictionaryEmptyFixtureJSON(word: dictionaryRequestWord(request), sourceURL: "https://fixture.example/unexpected"),
         dictionaryHTTPResponse(request.url!, statusCode: 500))
    }
    let diskService = DictionaryLookupService(
        transport: diskTransport,
        cacheDirectoryURL: cacheDirectory
    )
    let diskAliased = try await diskService.lookup(language: .zh, word: simplifiedWord)
    try expectDictionary(diskTransport.requestCount == 0,
                         "A successful script alias did not survive to the original disk cache key.")
    try expectDictionary(diskAliased.word == simplifiedWord
        && diskAliased.entries.first?.headword == traditionalWord
        && diskAliased.entries.first?.readings == ["cān kǎo"],
        "The disk-cached script alias did not preserve the original word and entry data.")

    let primarySuccessTransport = DictionaryFixtureTransport { request in
        let word = dictionaryRequestWord(request)
        return (
            dictionaryFixtureJSON(word: word, code: "zh", languageName: "Chinese"),
            dictionaryHTTPResponse(request.url!, statusCode: 200)
        )
    }
    let primarySuccessDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-script-primary-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: primarySuccessDirectory) }
    let primarySuccessService = DictionaryLookupService(
        transport: primarySuccessTransport,
        cacheDirectoryURL: primarySuccessDirectory
    )
    _ = try await primarySuccessService.lookup(language: .zh, word: "成功")
    try expectDictionary(primarySuccessTransport.requestCount == 1,
                         "A successful primary Chinese lookup unnecessarily requested a script variant.")

    let reverseCacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-script-reverse-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: reverseCacheDirectory) }
    let reverseTransport = DictionaryFixtureTransport { request in
        let word = dictionaryRequestWord(request)
        let payload = word == simplifiedWord
            ? dictionaryVariantFixtureJSON(
                word: word,
                reading: "cān kǎo",
                sourceURL: "https://fixture.example/variant/参考"
            )
            : dictionaryEmptyFixtureJSON(word: word, sourceURL: "https://fixture.example/variant/empty")
        return (payload, dictionaryHTTPResponse(request.url!, statusCode: 200))
    }
    let reverseService = DictionaryLookupService(
        transport: reverseTransport,
        cacheDirectoryURL: reverseCacheDirectory
    )
    let reverseAliased = try await reverseService.lookup(language: .traditionalChinese, word: traditionalWord)
    try expectDictionary(reverseAliased.word == traditionalWord
        && reverseAliased.entries.first?.headword == simplifiedWord,
        "Reverse Traditional-to-Simplified fallback did not preserve both words.")
    try expectDictionary(reverseTransport.requestCount == 2,
                         "Traditional miss did not request its distinct Simplified variant.")
    try expectDictionary(reverseTransport.requestURLs.allSatisfy { $0.path.contains("/zh/") },
                         "Traditional lookup must keep the provider endpoint at base zh.")

    let unknownCacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-script-unknown-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: unknownCacheDirectory) }
    let unknownTransport = DictionaryFixtureTransport { request in
        let word = dictionaryRequestWord(request)
        return (
            dictionaryEmptyFixtureJSON(word: word, sourceURL: "https://fixture.example/variant/empty"),
            dictionaryHTTPResponse(request.url!, statusCode: 200)
        )
    }
    let unknownService = DictionaryLookupService(
        transport: unknownTransport,
        cacheDirectoryURL: unknownCacheDirectory
    )
    do {
        _ = try await unknownService.lookup(language: .zh, word: "未知詞條")
        throw DictionaryCheckFailure(description: "Unknown Chinese script variants unexpectedly produced an entry.")
    } catch let error as DictionaryAPIError {
        try expectDictionary(error == .noEntries, "Unknown Chinese script variants returned the wrong error.")
    }
    try expectDictionary(unknownTransport.requestCount == 2,
                         "Unknown Chinese term did not stop after its one distinct script variant.")
    let unknownCached = await unknownService.cachedLookup(language: .zh, word: "未知詞條")
    try expectDictionary(unknownCached == nil,
                         "An unknown script fallback miss populated the original cache key.")

    let rateLimitDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-script-rate-limit-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rateLimitDirectory) }
    let rateLimitedTransport = DictionaryFixtureTransport { request in
        (
            Data(#"{"message":"slow down"}"#.utf8),
            dictionaryHTTPResponse(request.url!, statusCode: 429, headers: ["Retry-After": "3"])
        )
    }
    let rateLimitedService = DictionaryLookupService(
        transport: rateLimitedTransport,
        cacheDirectoryURL: rateLimitDirectory
    )
    do {
        _ = try await rateLimitedService.lookup(language: .zh, word: simplifiedWord)
        throw DictionaryCheckFailure(description: "Chinese HTTP 429 did not fail the lookup.")
    } catch let error as DictionaryAPIError {
        guard case .rateLimited = error else {
            throw DictionaryCheckFailure(description: "Chinese HTTP 429 returned the wrong error: \(error)")
        }
    }
    try expectDictionary(rateLimitedTransport.requestCount == 1,
                         "Rate limiting incorrectly triggered a Chinese script variant request.")

    let malformedDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-script-malformed-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: malformedDirectory) }
    let malformedTransport = DictionaryFixtureTransport { request in
        (
            Data(#"{"word":"参考","entries":[{"language":{"code":"zh","name":"Chinese"}}]}"#.utf8),
            dictionaryHTTPResponse(request.url!, statusCode: 200)
        )
    }
    let malformedService = DictionaryLookupService(
        transport: malformedTransport,
        cacheDirectoryURL: malformedDirectory
    )
    do {
        _ = try await malformedService.lookup(language: .zh, word: simplifiedWord)
        throw DictionaryCheckFailure(description: "Malformed Chinese response unexpectedly succeeded.")
    } catch let error as DictionaryAPIError {
        guard case .malformedResponse = error else {
            throw DictionaryCheckFailure(description: "Malformed Chinese response returned the wrong error: \(error)")
        }
    }
    try expectDictionary(malformedTransport.requestCount == 1,
                         "Malformed Chinese data incorrectly triggered a script variant request.")

    let unavailableDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-script-unavailable-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: unavailableDirectory) }
    let unavailableTransport = DictionaryFixtureTransport { request in
        (
            Data(#"{"message":"unavailable"}"#.utf8),
            dictionaryHTTPResponse(request.url!, statusCode: 503)
        )
    }
    let unavailableService = DictionaryLookupService(
        transport: unavailableTransport,
        cacheDirectoryURL: unavailableDirectory
    )
    do {
        _ = try await unavailableService.lookup(language: .zh, word: simplifiedWord)
        throw DictionaryCheckFailure(description: "Chinese HTTP 503 unexpectedly succeeded.")
    } catch let error as DictionaryAPIError {
        guard case let .httpStatus(status, _) = error, status == 503 else {
            throw DictionaryCheckFailure(description: "Chinese HTTP 503 returned the wrong error: \(error)")
        }
    }
    try expectDictionary(unavailableTransport.requestCount == 1,
                         "Unavailable Chinese data incorrectly triggered a script variant request.")

    let japaneseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-script-japanese-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: japaneseDirectory) }
    let japaneseTransport = DictionaryFixtureTransport { request in
        (
            dictionaryEmptyFixtureJSON(word: dictionaryRequestWord(request), sourceURL: "https://fixture.example/variant/empty"),
            dictionaryHTTPResponse(request.url!, statusCode: 200)
        )
    }
    let japaneseService = DictionaryLookupService(
        transport: japaneseTransport,
        cacheDirectoryURL: japaneseDirectory
    )
    do {
        _ = try await japaneseService.lookup(language: .ja, word: "食べる")
        throw DictionaryCheckFailure(description: "Japanese lookup unexpectedly converted through Chinese variants.")
    } catch let error as DictionaryAPIError {
        try expectDictionary(error == .noEntries, "Japanese miss returned the wrong error.")
    }
    try expectDictionary(japaneseTransport.requestCount == 1,
                         "Japanese lookup incorrectly requested a Chinese script variant.")
}

private func dictionaryHTTPErrorChecks() async throws {
    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-http-error-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }

    let rateLimitedTransport = DictionaryFixtureTransport { request in
        let response = dictionaryHTTPResponse(
            request.url!,
            statusCode: 429,
            headers: ["Retry-After": "3"]
        )
        return (Data(#"{"message":"slow down"}"#.utf8), response)
    }
    let rateLimitedService = DictionaryLookupService(
        transport: rateLimitedTransport,
        cacheDirectoryURL: cacheDirectory.appendingPathComponent("rate-limited", isDirectory: true)
    )
    do {
        _ = try await rateLimitedService.lookup(language: .en, word: "hello")
        throw DictionaryCheckFailure(description: "HTTP 429 did not fail the dictionary lookup.")
    } catch let error as DictionaryAPIError {
        guard case let .rateLimited(retryAfter) = error else {
            throw DictionaryCheckFailure(description: "HTTP 429 returned the wrong dictionary error: \(error)")
        }
        try expectDictionary(retryAfter == 3, "Retry-After was not parsed from HTTP 429.")
    }

    let notFoundTransport = DictionaryFixtureTransport { request in
        let response = dictionaryHTTPResponse(request.url!, statusCode: 404)
        return (Data(#"{"error":{"message":"word not found"}}"#.utf8), response)
    }
    let notFoundService = DictionaryLookupService(
        transport: notFoundTransport,
        cacheDirectoryURL: cacheDirectory.appendingPathComponent("not-found", isDirectory: true)
    )
    do {
        _ = try await notFoundService.lookup(language: .en, word: "missing")
        throw DictionaryCheckFailure(description: "HTTP 404 did not fail the dictionary lookup.")
    } catch let error as DictionaryAPIError {
        guard case let .httpStatus(status, message) = error, status == 404, message == "word not found" else {
            throw DictionaryCheckFailure(description: "HTTP 404 returned the wrong dictionary error: \(error)")
        }
    }

    let malformedTransport = DictionaryFixtureTransport { request in
        let response = dictionaryHTTPResponse(request.url!, statusCode: 200)
        return (Data(#"{"word":"broken","entries":[{"language":{"code":"en","name":"English"}}]}"#.utf8), response)
    }
    let malformedService = DictionaryLookupService(
        transport: malformedTransport,
        cacheDirectoryURL: cacheDirectory.appendingPathComponent("malformed", isDirectory: true)
    )
    do {
        _ = try await malformedService.lookup(language: .en, word: "broken")
        throw DictionaryCheckFailure(description: "Malformed dictionary JSON did not fail the lookup.")
    } catch let error as DictionaryAPIError {
        guard case .malformedResponse = error else {
            throw DictionaryCheckFailure(description: "Malformed dictionary JSON returned the wrong error: \(error)")
        }
    }
}

private func dictionaryCancellationChecks() async throws {
    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-cancellation-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let transport = CancellableDictionaryFixtureTransport(
        result: dictionaryFixtureJSON(word: "cancelled", code: "en", languageName: "English")
    )
    let service = DictionaryLookupService(
        transport: transport,
        cacheDirectoryURL: cacheDirectory
    )
    let lookupTask = Task {
        try await service.lookup(language: .en, word: "cancelled", useCache: false)
    }

    for _ in 0..<100 where transport.requestCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    try expectDictionary(transport.requestCount == 1, "Cancellation fixture did not start its network request.")

    lookupTask.cancel()
    do {
        _ = try await lookupTask.value
        throw DictionaryCheckFailure(description: "A canceled dictionary lookup returned a result.")
    } catch is CancellationError {
        // Expected: canceling the only waiter cancels the shared fetch.
    }

    for _ in 0..<100 where transport.cancellationCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    try expectDictionary(
        transport.cancellationCount == 1,
        "Canceling the final dictionary waiter did not cancel its underlying fetch."
    )
    let cachedResult = await service.cachedLookup(language: .en, word: "cancelled")
    try expectDictionary(cachedResult == nil, "A canceled dictionary lookup populated the raw cache.")
}

private func dictionaryTypedAIChecks() async throws {
    let sentenceResponse = #"{"model":"fixture-openai","choices":[{"message":{"content":"{\"kind\":\"sentence_context\",\"translation\":\"Hello world\",\"segmentation\":[{\"text\":\"Hola\",\"start_utf16\":0,\"length_utf16\":4,\"language\":\"es\"}],\"readings\":[\"ola\"],\"contextual_meaning\":null,\"target_definitions\":[],\"example_translations\":[]}","refusal":null},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}"#
    let openAITransport = DictionaryFixtureTransport { request in
        (Data(sentenceResponse.utf8), dictionaryHTTPResponse(request.url!, statusCode: 200))
    }
    let openAIConfiguration = AIProviderConfiguration(
        provider: .openAICompatible,
        endpoint: URL(string: "https://fixture.example/v1/chat/completions")!,
        model: "fixture-openai"
    )
    let sentenceRequest = DictionaryAIRequest.sentenceContext(
        sourceText: "Hola mundo",
        sourceLanguage: .es,
        targetLanguage: .en,
        focusToken: DictionaryToken(
            text: "Hola",
            sourceRange: NSRange(location: 0, length: 4),
            language: .es
        ),
        includeSegmentation: true,
        includeReadings: true
    )
    let openAIClient = AIProviderClient(transport: openAITransport)
    let openAIRequest = try openAIClient.makeDictionaryRequest(
        request: sentenceRequest,
        apiKey: "fixture-key",
        safetyIdentifier: "fixture-safe",
        configuration: openAIConfiguration
    )
    let openAIBody = try expectDictionaryJSON(openAIRequest.httpBody, "OpenAI dictionary request did not contain JSON.")
    let chineseSentenceRequest = DictionaryAIRequest.sentenceContext(
        sourceText: "I cannot continue.", sourceLanguage: .en,
        targetLanguage: .traditionalChinese
    )
    let chineseOpenAIRequest = try openAIClient.makeDictionaryRequest(
        request: chineseSentenceRequest, apiKey: "fixture-key", safetyIdentifier: "fixture-safe",
        configuration: openAIConfiguration
    )
    let chineseOpenAIBody = try expectDictionaryJSON(chineseOpenAIRequest.httpBody, "Chinese OpenAI body is missing.")
    let chineseOpenAIInstructions = (chineseOpenAIBody["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
    try expectDictionary(chineseOpenAIInstructions.contains("Traditional Chinese (zh-Hant)"),
                         "OpenAI Dictionary sentence prompt lost Traditional target script.")
    let paragraphSource = "First line.\nSecond line with  meaning."
    let paragraphRequest = DictionaryAIRequest.sentenceContext(
        sourceText: paragraphSource, sourceLanguage: .en,
        targetLanguage: .traditionalChinese, includeSegmentation: false,
        includeReadings: false, singleParagraph: true
    )
    let paragraphOpenAI = try openAIClient.makeDictionaryRequest(
        request: paragraphRequest, apiKey: "fixture-key", safetyIdentifier: "fixture-safe",
        configuration: openAIConfiguration
    )
    let paragraphBody = try expectDictionaryJSON(paragraphOpenAI.httpBody, "Paragraph OpenAI request is missing.")
    let paragraphMessages = paragraphBody["messages"] as? [[String: Any]]
    let paragraphInstructions = paragraphMessages?.first?["content"] as? String ?? ""
    let paragraphInput = ((paragraphMessages?.last?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    try expectDictionary(paragraphInstructions.contains("one natural paragraph")
                         && paragraphInstructions.contains("complete source text"),
                         "OpenAI paragraph prompt is missing its one-paragraph contract.")
    try expectDictionary(paragraphInstructions.contains("Traditional Chinese (zh-Hant)")
                         && paragraphInstructions.contains("Do not use lists, headings, commentary, or Markdown"),
                         "OpenAI paragraph prompt lost target script or output constraints.")
    try expectDictionary(paragraphInput.contains(paragraphSource),
                         "OpenAI paragraph input altered the full multiline source.")
    try expectDictionary(DictionaryParagraphTranslation.normalized("  First  line.\n\n Second line.  ") == "First  line. Second line.",
                         "Paragraph normalization changed internal spaces or kept line breaks.")
    let openAIFormat = ((openAIBody["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])
    try expectDictionary(openAIFormat?["name"] as? String == "dictionary_response", "OpenAI dictionary schema name was missing.")
    let indexedRequest = try openAIClient.makeDictionaryRequest(
        request: .sentenceContext(sourceText: "💡 参考资料。参考", sourceLanguage: .zh,
                                  targetLanguage: .en, includeSegmentation: true, includeReadings: false),
        apiKey: "fixture-key", safetyIdentifier: "fixture-safe", configuration: openAIConfiguration
    )
    let indexedBody = try expectDictionaryJSON(indexedRequest.httpBody, "Indexed sentence request is missing.")
    let indexedMessages = indexedBody["messages"] as? [[String: Any]]
    let indexedContent = indexedMessages?.last?["content"] as? [[String: Any]]
    let indexedText = indexedContent?.first?["text"] as? String ?? ""
    let positionMarker = "Character position guide (UTF-16, not word boundaries):\n"
    try expectDictionary(indexedText.contains(positionMarker), "AI segmentation must receive machine-calculated UTF-16 positions.")
    let guideJSON = indexedText.components(separatedBy: positionMarker).last ?? ""
    let positions = try JSONDecoder().decode([DictionaryToken].self, from: Data(guideJSON.utf8))
    try expectDictionary(positions.first?.sourceRange == NSRange(location: 0, length: 2),
                         "The AI position guide counted a surrogate pair as one UTF-16 unit.")
    try expectDictionary(positions.filter { $0.text == "参" }.map(\.sourceRange) ==
                            [NSRange(location: 3, length: 1), NSRange(location: 8, length: 1)],
                         "The AI position guide lost the offsets of repeated Chinese text.")
    try expectDictionary(positions.map(\.text).joined() == "💡 参考资料。参考",
                         "The AI position guide altered whitespace or punctuation.")
    let openAIResponse = try await openAIClient.completeDictionary(
        request: sentenceRequest,
        apiKey: "fixture-key",
        safetyIdentifier: "fixture-safe",
        configuration: openAIConfiguration
    )
    try expectDictionary(openAIResponse.translation == "Hello world", "OpenAI typed dictionary translation was not decoded.")
    try expectDictionary(openAIResponse.segmentedTokens.first?.sourceRange == NSRange(location: 0, length: 4), "OpenAI typed token range was not decoded as UTF-16.")

    let entry = DictionaryEntry(
        headword: "hola",
        language: .es,
        partOfSpeech: "interjection",
        pronunciations: [DictionaryPronunciation(text: "/ola/")],
        senses: [DictionarySense(definition: "greeting")]
    )
    let entryResponse = #"{"model":"fixture-anthropic","content":[{"type":"text","text":"{\"kind\":\"entry_enrichment\",\"translation\":null,\"segmentation\":[],\"readings\":[\"ola\"],\"contextual_meaning\":\"A friendly greeting\",\"target_definitions\":[\"hello\"],\"example_translations\":[{\"source\":\"Hola, Ana.\",\"translation\":\"Hello, Ana.\"},{\"source\":\"Hola a todos.\",\"translation\":\"Hello everyone.\"}]}"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":2}}"#
    let anthropicTransport = DictionaryFixtureTransport { request in
        (Data(entryResponse.utf8), dictionaryHTTPResponse(request.url!, statusCode: 200))
    }
    let anthropicConfiguration = AIProviderConfiguration(
        provider: .anthropic,
        endpoint: URL(string: "https://fixture.example/v1/messages")!,
        model: "fixture-anthropic"
    )
    let paragraphAnthropic = try openAIClient.makeDictionaryRequest(
        request: paragraphRequest, apiKey: "fixture-key", safetyIdentifier: "fixture-safe",
        configuration: anthropicConfiguration
    )
    let paragraphAnthropicBody = try expectDictionaryJSON(paragraphAnthropic.httpBody, "Paragraph Anthropic request is missing.")
    let anthropicInstructions = paragraphAnthropicBody["system"] as? String ?? ""
    let anthropicInput = ((paragraphAnthropicBody["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    try expectDictionary(anthropicInstructions.contains("one natural paragraph")
                         && anthropicInstructions.contains("Traditional Chinese (zh-Hant)")
                         && anthropicInput.contains(paragraphSource),
                         "Anthropic paragraph prompt lost the full source or translation contract.")
    let entryRequest = DictionaryAIRequest.entryEnrichment(
        entry: entry,
        sentence: "Hola, Ana.",
        sourceLanguage: .es,
        targetLanguage: .en,
        focusToken: DictionaryToken(text: "Hola", range: NSRange(location: 0, length: 4), language: .es)
    )
    let anthropicClient = AIProviderClient(transport: anthropicTransport)
    let anthropicRequest = try anthropicClient.makeDictionaryRequest(
        request: entryRequest,
        apiKey: "fixture-key",
        safetyIdentifier: "fixture-safe",
        configuration: anthropicConfiguration
    )
    let anthropicBody = try expectDictionaryJSON(anthropicRequest.httpBody, "Anthropic dictionary request did not contain JSON.")
    let chineseEntry = DictionaryEntry(
        headword: "無法", language: .zh,
        senses: [DictionarySense(definition: "unable", examples: [
            "我現在已經無法直視他了。", "我现在已经无法直视他了。"
        ])]
    )
    let chineseEntryRequest = DictionaryAIRequest.entryEnrichment(
        entry: chineseEntry, sentence: "无法", sourceLanguage: .zh,
        targetLanguage: .traditionalChinese
    )
    let chineseOpenAIEntryRequest = try openAIClient.makeDictionaryRequest(
        request: chineseEntryRequest, apiKey: "fixture-key", safetyIdentifier: "fixture-safe",
        configuration: openAIConfiguration
    )
    let chineseOpenAIEntryBody = try expectDictionaryJSON(chineseOpenAIEntryRequest.httpBody, "Chinese OpenAI entry body is missing.")
    let chineseOpenAIEntryInstructions = (chineseOpenAIEntryBody["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
    try expectDictionary(chineseOpenAIEntryInstructions.contains("Simplified Chinese (zh-Hans)") &&
                         chineseOpenAIEntryInstructions.contains("Traditional Chinese (zh-Hant)"),
                         "OpenAI Dictionary enrichment prompt lost source or target script.")
    let chineseAnthropicRequest = try anthropicClient.makeDictionaryRequest(
        request: chineseEntryRequest, apiKey: "fixture-key", safetyIdentifier: "fixture-safe",
        configuration: anthropicConfiguration
    )
    let chineseAnthropicBody = try expectDictionaryJSON(chineseAnthropicRequest.httpBody, "Chinese Anthropic body is missing.")
    let chineseAnthropicInstructions = chineseAnthropicBody["system"] as? String ?? ""
    try expectDictionary(chineseAnthropicInstructions.contains("Simplified Chinese (zh-Hans)") &&
                         chineseAnthropicInstructions.contains("Traditional Chinese (zh-Hant)") &&
                         chineseAnthropicInstructions.contains("fewer than two distinct"),
                         "Anthropic Dictionary enrichment prompt lost script or distinct-example policy.")
    let chineseAnthropicInput = ((chineseAnthropicBody["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    try expectDictionary(chineseAnthropicInput.components(separatedBy: "我現在已經無法直視他了。").count == 2 &&
                         !chineseAnthropicInput.contains("我现在已经无法直视他了。"),
                         "AI context kept script-equivalent source examples twice.")
    let chineseAnthropicSentenceRequest = try anthropicClient.makeDictionaryRequest(
        request: chineseSentenceRequest, apiKey: "fixture-key", safetyIdentifier: "fixture-safe",
        configuration: anthropicConfiguration
    )
    let chineseAnthropicSentenceBody = try expectDictionaryJSON(chineseAnthropicSentenceRequest.httpBody, "Chinese Anthropic sentence body is missing.")
    try expectDictionary((chineseAnthropicSentenceBody["system"] as? String)?.contains("Traditional Chinese (zh-Hant)") == true,
                         "Anthropic Dictionary sentence prompt lost Traditional target script.")
    try expectDictionary((anthropicBody["output_config"] as? [String: Any]) != nil, "Anthropic dictionary schema was missing.")
    let anthropicResponse = try await anthropicClient.completeDictionary(
        request: entryRequest,
        apiKey: "fixture-key",
        safetyIdentifier: "fixture-safe",
        configuration: anthropicConfiguration
    )
    try expectDictionary(anthropicResponse.contextualMeaning == "A friendly greeting", "Anthropic contextual meaning was not decoded.")
    try expectDictionary(anthropicResponse.exampleTranslations.count == 2, "Anthropic example translations were not decoded.")

    let malformedAITransport = DictionaryFixtureTransport { request in
        let payload = #"{"model":"fixture","choices":[{"message":{"content":"not json"},"finish_reason":"stop"}]}"#
        return (Data(payload.utf8), dictionaryHTTPResponse(request.url!, statusCode: 200))
    }
    let malformedClient = AIProviderClient(transport: malformedAITransport)
    do {
        _ = try await malformedClient.completeDictionary(
            request: sentenceRequest,
            apiKey: "fixture-key",
            safetyIdentifier: "fixture-safe",
            configuration: openAIConfiguration
        )
        throw DictionaryCheckFailure(description: "Malformed AI dictionary output did not fail.")
    } catch let error as ResponsesAPIError {
        guard case .invalidOutput = error else {
            throw DictionaryCheckFailure(description: "Malformed AI dictionary output returned the wrong error: \(error)")
        }
    }
}

private func expectDictionaryEntry(
    _ entry: DictionaryEntry?,
    _ message: String
) throws -> DictionaryEntry {
    guard let entry else {
        throw DictionaryCheckFailure(description: message)
    }
    return entry
}

private func expectDictionaryJSON(
    _ data: Data?,
    _ message: String
) throws -> [String: Any] {
    guard let data, let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else {
        throw DictionaryCheckFailure(description: message)
    }
    return dictionary
}

private func dictionaryRequestWord(_ request: URLRequest) -> String {
    guard let url = request.url else { return "" }
    return dictionaryRequestWord(url)
}

private func dictionaryRequestWord(_ url: URL) -> String {
    let pathWord = url.path.split(separator: "/").last.map(String.init) ?? ""
    return pathWord.removingPercentEncoding ?? pathWord
}

private func dictionaryEmptyFixtureJSON(word: String, sourceURL: String) -> Data {
    let object: [String: Any] = [
        "word": word,
        "entries": [],
        "source": [
            "url": sourceURL,
            "license": [
                "name": "CC BY-SA",
                "url": "https://creativecommons.org/licenses/by-sa/",
            ],
        ],
    ]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func dictionaryVariantFixtureJSON(
    word: String,
    reading: String,
    sourceURL: String
) -> Data {
    let object: [String: Any] = [
        "word": word,
        "entries": [
            [
                "language": ["code": "zh", "name": "Chinese"],
                "partOfSpeech": "noun",
                "pronunciations": [
                    ["type": "pinyin", "text": reading, "tags": ["Mandarin"]],
                ],
                "forms": [["word": word, "tags": ["canonical"]]],
                "senses": [
                    [
                        "definition": "A script variant fixture.",
                        "tags": [],
                        "examples": ["A script variant example."],
                        "subsenses": [],
                        "translations": [
                            [
                                "language": ["code": "en", "name": "English"],
                                "word": "reference",
                                "definition": "A reference.",
                            ],
                        ],
                    ],
                ],
            ],
        ],
        "source": [
            "url": sourceURL,
            "license": [
                "name": "CC BY-SA",
                "url": "https://creativecommons.org/licenses/by-sa/",
            ],
        ],
    ]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func dictionaryHTTPResponse(
    _ url: URL,
    statusCode: Int,
    headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}

private func dictionaryFixtureJSON(
    word: String,
    code: String,
    languageName: String
) -> Data {
    let object: [String: Any] = [
        "word": word,
        "entries": [
            [
                "language": ["code": code, "name": languageName],
                "partOfSpeech": "noun",
                "pronunciations": [["type": "phonetic", "text": "/fixture/", "tags": []]],
                "forms": [["word": word, "tags": ["singular"]]],
                "senses": [
                    [
                        "definition": "An English gloss.",
                        "tags": [],
                        "examples": ["A fixture example."],
                        "subsenses": [],
                        "translations": [["language": ["code": "en", "name": "English"], "word": "gloss", "definition": "English gloss"]],
                    ],
                ],
            ],
        ],
        "source": [
            "url": "https://fixture.example/entry",
            "license": ["name": "CC BY-SA", "url": "https://creativecommons.org/licenses/by-sa/"],
        ],
    ]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}
