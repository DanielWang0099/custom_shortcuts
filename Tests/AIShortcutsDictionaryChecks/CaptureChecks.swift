import AIShortcutsCore
import AppKit
import Foundation

private struct CaptureCheckFailure: Error, CustomStringConvertible, LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

private func requireCapture(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CaptureCheckFailure(description: message) }
}

private final class CaptureDictionaryTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    let delay: UInt64
    let status: Int
    let ignoresCancellation: Bool
    let senseCount: Int
    let dictionaryReading: String?
    let chineseExamples: [String]?

    init(delay: UInt64 = 0, status: Int = 200, ignoresCancellation: Bool = false,
         senseCount: Int = 1, dictionaryReading: String? = nil,
         chineseExamples: [String]? = nil) {
        self.delay = delay
        self.status = status
        self.ignoresCancellation = ignoresCancellation
        self.senseCount = senseCount
        self.dictionaryReading = dictionaryReading
        self.chineseExamples = chineseExamples
    }

    var requests: [String] { lock.withLock { paths } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { paths.append(request.url!.path) }
        if delay > 0 {
            if ignoresCancellation {
                // Simulate a transport that returns a late response after its
                // waiter was canceled; the coordinator must reject it by
                // generation before it can replace the newer lookup.
                let duration = delay
                let timer = Task.detached {
                    try? await Task.sleep(nanoseconds: duration)
                }
                await timer.value
            } else {
                try await Task.sleep(nanoseconds: delay)
            }
        }
        if status == 0 { throw URLError(.notConnectedToInternet) }
        let pieces = request.url!.path.split(separator: "/")
        let word = String(pieces.last!)
        let code = String(pieces.dropLast().last!)
        if let chineseExamples {
            let object: [String: Any] = [
                "word": word,
                "entries": [["word": "無法 (无法)", "language": ["code": code, "name": code],
                             "partOfSpeech": "verb",
                             "senses": [["definition": "unable", "examples": chineseExamples]]]],
                "source": ["url": "https://en.wiktionary.org/wiki/%E7%84%A1%E6%B3%95"]
            ]
            return (try JSONSerialization.data(withJSONObject: object),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let object: [String: Any] = [
            "word": word,
            "entries": [["language": ["code": code, "name": code],
                         "partOfSpeech": "noun",
                         "readings": dictionaryReading.map { [$0] } ?? [],
                         "senses": (0..<senseCount).map { index -> [String: Any] in
                             var sense: [String: Any] = ["definition": senseCount == 1 ? "fixture definition for \(word)" : "fixture definition \(index + 1) for \(word)"]
                             if index == 0 {
                                 sense["examples"] = ["Example one for \(word).", "Example two for \(word)."]
                                 if senseCount > 1 {
                                     sense["subsenses"] = [["definition": "nested sense for \(word)",
                                                             "subsenses": [["definition": "deep nested sense for \(word)"]]]]
                                 }
                             }
                             return sense
                         }]],
            "source": ["url": "https://en.wiktionary.org/wiki/\(word)",
                       "license": ["name": "CC BY-SA 4.0", "url": "https://creativecommons.org/licenses/by-sa/4.0/"]],
        ]
        return (try JSONSerialization.data(withJSONObject: object),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private final class CaptureFixture {
    let name = "AIShortcuts.CaptureChecks.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-capture-\(UUID().uuidString)")
    let defaults: UserDefaults
    let panel = DictionaryPanelController(presentationMode: .offscreenTest)
    let transport: CaptureDictionaryTransport
    let historyStore: DictionaryHistoryStore
    var coordinator: DictionaryCoordinator!
    var events: [String] = []
    var contexts: [String] = []
    var paragraphRequests: [DictionarySentenceContextRequest] = []
    var paragraphCompletions: [DictionarySentenceContextRequest] = []
    var enrichmentLanguages: [String] = []
    var enrichmentReadings: [String] = []
    var enrichmentCount = 0
    var chineseOppositeAI = false
    var failContext = false
    var paragraphDelay: UInt64 = 160_000_000
    var ignoreParagraphCancellation = false
    var missingParagraphTranslation = false
    var malformedParagraphResponse = false
    var paragraphOutput: String?
    var paragraphOutputForRequest: ((DictionarySentenceContextRequest) -> String?)?
    var selected: String?
    var recognized: String
    var screenshot: Data?
    var captureError = false
    var selectionDelay: UInt64 = 0
    var contextSegmentation: [DictionaryToken]

    init(selected: String?, recognized: String = "", screenshot: Data? = Data([1]),
         accessibility: Bool = true, screen: Bool = true, transport: CaptureDictionaryTransport = .init(),
         useAI: Bool = false, contextSegmentation: [DictionaryToken] = [],
         nativeRefinement: DictionaryCoordinator.NativeRefinement? = nil, targetLanguage: String = "en",
         presentationMode: DictionaryPresentationMode = .dictionary) {
        defaults = UserDefaults(suiteName: name)!
        self.selected = selected
        self.recognized = recognized
        self.screenshot = screenshot
        self.transport = transport
        historyStore = DictionaryHistoryStore(fileURL: nil)
        self.contextSegmentation = contextSegmentation
        let dependencies = DictionaryCoordinator.CaptureDependencies(
            accessibilityTrusted: { accessibility }, screenRecordingGranted: { screen },
            selectedText: { [weak self] in
                guard let self else { return nil }
                self.events.append("selection")
                // Deliberately finish after cancellation to test generation guards.
                if self.selectionDelay > 0 { try? await Task.sleep(nanoseconds: self.selectionDelay) }
                return self.selected
            },
            screenshotPNG: { [weak self] in
                guard let self else { return nil }
                self.events.append("screenshot")
                if self.captureError { throw CaptureCheckFailure(description: "fixture screenshot failure") }
                return self.screenshot
            }, recognizeText: { [weak self] _ in
                self?.events.append("OCR")
                return self?.recognized ?? ""
            }
        )
        var completion: DictionaryCoordinator.AICompletion?
        if useAI {
            completion = { [weak self] (request: DictionaryAIRequest) async throws -> DictionaryAIResponse in
                switch request {
                case let .sentenceContext(context):
                    self?.contexts.append(context.sourceText + ":" + (context.targetLanguage?.rawValue ?? "en"))
                    if context.singleParagraph { self?.paragraphRequests.append(context) }
                    if self?.failContext == true { throw CaptureCheckFailure(description: "fixture context failure") }
                    // Capture each response before waiting. A late response must
                    // retain its old query/target even after the fixture changes.
                    let malformed = context.singleParagraph && self?.malformedParagraphResponse == true
                    let missing = context.singleParagraph && self?.missingParagraphTranslation == true
                    let output = self?.paragraphOutputForRequest?(context) ?? self?.paragraphOutput
                        ?? (self?.chineseOppositeAI == true && context.targetLanguage?.endpointCode == "zh"
                            ? "无法继续" : "Translated: " + context.sourceText)
                    let delay = context.singleParagraph ? (self?.paragraphDelay ?? 160_000_000) : 160_000_000
                    if context.singleParagraph && self?.ignoreParagraphCancellation == true {
                        let sleeper = Task.detached { try? await Task.sleep(nanoseconds: delay) }
                        await sleeper.value
                    } else {
                        try await Task.sleep(nanoseconds: delay)
                    }
                    if context.singleParagraph { self?.paragraphCompletions.append(context) }
                    if malformed {
                        return DictionaryAIResponse(kind: .entryEnrichment)
                    }
                    return DictionaryAIResponse(
                        kind: .sentenceContext,
                        translation: missing ? nil : output,
                        segmentedTokens: self?.contextSegmentation ?? []
                    )
                case let .entryEnrichment(request):
                    if let language = request.focusToken?.language?.rawValue {
                        self?.enrichmentLanguages.append(language)
                    }
                    self?.enrichmentCount += 1
                    if self?.chineseOppositeAI == true {
                        return DictionaryAIResponse(
                            kind: .entryEnrichment,
                            contextualMeaning: "无法继续",
                            targetDefinitions: ["无法做到"],
                            exampleTranslations: [
                                DictionaryExampleTranslation(source: "我現在已經無法直視他了。", translation: "无法直视他"),
                                DictionaryExampleTranslation(source: "我無法繼續。", translation: "无法继续")
                            ]
                        )
                    }
                    return DictionaryAIResponse(kind: .entryEnrichment, readings: self?.enrichmentReadings ?? [])
                }
            }
        }
        AppStateStore(defaults: self.defaults).dictionaryTargetLanguage = targetLanguage
        AppStateStore(defaults: self.defaults).dictionaryPresentationMode = presentationMode
        coordinator = DictionaryCoordinator(
            stateStore: AppStateStore(defaults: self.defaults), selectionService: SelectionService(),
            screenshotService: ScreenshotService(), panel: self.panel,
            lookupService: DictionaryLookupService(transport: self.transport, cacheDirectoryURL: self.directory),
            historyStore: self.historyStore,
            captureDependencies: dependencies,
            aiCompletion: completion,
            nativeRefinement: nativeRefinement)
    }

    func clean() {
        coordinator.releaseResources()
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: directory)
    }

    var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "Dictionary" }
    }

    var controls: [NSView] {
        guard let content = window?.contentView else { return [] }
        return DictionaryNativeChecks.descendants(content)
    }

    var lookupField: NSTextField? { controls.compactMap { $0 as? NSTextField }.first { $0.isEditable } }

    var labels: [String] {
        controls.compactMap { ($0 as? NSTextField)?.stringValue }
    }

    func start() async throws {
        coordinator.start()
        try await waitUntil { self.panel.isVisible }
    }

    func click(_ label: String) throws {
        guard let button = controls.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == label }),
              button.isEnabled else { throw CaptureCheckFailure(description: "Missing enabled button \(label)") }
        guard let action = button.action else { throw CaptureCheckFailure(description: "Button has no action") }
        _ = NSApp.sendAction(action, to: button.target, from: button)
    }

    func submit(_ query: String) throws {
        guard let field = lookupField else { throw CaptureCheckFailure(description: "No lookup field") }
        field.stringValue = query
        guard let delegate = field.delegate as? DictionaryPanelController else {
            throw CaptureCheckFailure(description: "No lookup delegate")
        }
        _ = delegate.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    func chooseLanguage(_ rawValue: String, source: Bool = false) throws {
        let identifier = source ? "dictionary.source" : "dictionary.target"
        guard let menu = controls.compactMap({ $0 as? NSPopUpButton }).first(where: {
            $0.accessibilityIdentifier() == identifier
        }), let item = menu.itemArray.first(where: { ($0.representedObject as? String) == rawValue }),
              let action = menu.action else {
            throw CaptureCheckFailure(description: "Missing language choice \(rawValue)")
        }
        menu.select(item)
        _ = NSApp.sendAction(action, to: menu.target, from: menu)
    }
}

@MainActor
func dictionaryChineseScriptChecks() async throws {
    let pair = ["我現在已經無法直視他了。", "我现在已经无法直视他了。"]
    let fixture = CaptureFixture(
        selected: "无法", transport: .init(chineseExamples: pair),
        useAI: true, targetLanguage: "zh-hant"
    )
    defer { fixture.clean() }
    fixture.chineseOppositeAI = true
    try await fixture.start()
    try await waitUntil { fixture.labels.contains("我无法继续。") }
    try requireCapture(fixture.transport.requests.contains { $0.contains("/zh/") },
                       "Chinese variant lookup left the base zh endpoint")
    try requireCapture(fixture.labels.contains("无法"),
                       "Traditional provider headword replaced selected Simplified word")
    try requireCapture(fixture.labels.contains { $0.contains("Wiktionary") } &&
                       !fixture.labels.contains("The dictionary service returned an unreadable entry."),
                       "Traditional provider entry or attribution did not survive lookup")
    try requireCapture(fixture.labels.contains("我现在已经无法直视他了。") &&
                       !fixture.labels.contains("我現在已經無法直視他了。"),
                       "Source examples did not follow detected Simplified script")
    try requireCapture(fixture.labels.filter { $0 == "我现在已经无法直视他了。" }.count == 1,
                       "Script-equivalent provider examples were shown twice")
    try requireCapture(fixture.labels.contains { $0.contains("無法繼續") } &&
                       fixture.labels.contains { $0.contains("無法做到") },
                       "Opposite-script enrichment was not converted to Traditional target: \(fixture.labels)")
    let sourceMenu = fixture.controls.compactMap { $0 as? NSPopUpButton }
        .first { $0.accessibilityIdentifier() == "dictionary.source" }!
    try requireCapture(sourceMenu.itemTitles.contains("简体中文") && sourceMenu.itemTitles.contains("繁體中文"),
                       "Source popup lacks both native Chinese script choices")
    if let window = fixture.window {
        try DictionaryNativeChecks.savePreview(window, name: "chinese-simplified-selection")
    }
    sourceMenu.selectItem(withTitle: "繁體中文")
    _ = NSApp.sendAction(sourceMenu.action!, to: sourceMenu.target, from: sourceMenu)
    try await waitUntil { fixture.labels.contains("無法") }
    try requireCapture(fixture.lookupField?.stringValue == "无法",
                       "Explicit source script changed the original selection")
    fixture.clean()

    let distinct = CaptureFixture(
        selected: "无法", transport: .init(chineseExamples: pair + ["我無法離開。"])
    )
    defer { distinct.clean() }
    try await distinct.start()
    try await waitUntil { distinct.labels.contains("我无法离开。") }
    try requireCapture(distinct.labels.filter { $0 == "我现在已经无法直视他了。" }.count == 1,
                       "A duplicate script variant displaced a distinct provider example")
    distinct.clean()

    let english = CaptureFixture(selected: "I cannot continue.", useAI: true, targetLanguage: "zh-hant")
    defer { english.clean() }
    english.chineseOppositeAI = true
    try await english.start()
    try await waitUntil { english.controls.contains { $0.accessibilityLabel() == "Sentence translation: 無法繼續" } }
    let saved = english.historyStore.items.first!
    try requireCapture(saved.targetLanguage == "zh-hant", "History lost Traditional target")
    let targetMenu = english.controls.compactMap { $0 as? NSPopUpButton }
        .first { $0.accessibilityIdentifier() == "dictionary.target" }!
    targetMenu.selectItem(withTitle: "简体中文")
    _ = NSApp.sendAction(targetMenu.action!, to: targetMenu.target, from: targetMenu)
    try await waitUntil { english.contexts.contains("I cannot continue.:zh") &&
        english.controls.contains { $0.accessibilityLabel() == "Sentence translation: 无法继续" } }
    try requireCapture(english.contexts.contains("I cannot continue.:zh-hant") &&
                       english.contexts.contains("I cannot continue.:zh"),
                       "Sentence translation cache reused the wrong Chinese script: \(english.contexts)")
    english.coordinator.restoreHistory(DictionaryPanelHistoryItem(
        id: saved.id, query: saved.query, sourceLanguage: saved.sourceLanguage,
        detectedSourceLanguage: saved.detectedSourceLanguage,
        targetLanguage: saved.targetLanguage, lookedUpAt: saved.lookedUpAt
    ))
    try await waitUntil { english.controls.contains { $0.accessibilityLabel() == "Sentence translation: 無法繼續" } }
    try requireCapture(AppStateStore(defaults: english.defaults).dictionaryTargetLanguage == "zh-hant",
                       "History restore did not persist Traditional target")
    english.clean()
    let crossScript = CaptureFixture(selected: "我无法继续。", useAI: true, targetLanguage: "zh-hant")
    defer { crossScript.clean() }
    crossScript.chineseOppositeAI = true
    try await crossScript.start()
    try await waitUntil { crossScript.controls.contains {
        $0.accessibilityLabel() == "Sentence translation: 無法繼續"
    } }
    try requireCapture(crossScript.labels.contains("無法繼續"),
                       "Simplified source to Traditional target hid a real sentence translation")
    print("PASS Chinese script choices, fallback display, example deduplication, AI normalization, and history")
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw CaptureCheckFailure(description: "Timed out waiting for dictionary UI")
}

@MainActor
func dictionaryTranslationChecks() async throws {
    let source = "A complete captured paragraph begins here.\nIts second line contains the important ending."
    let translated = CaptureFixture(selected: source, useAI: true, presentationMode: .translate)
    defer { translated.clean() }
    try await translated.start()
    try await waitUntil { translated.labels.contains("Translated: " + DictionaryParagraphTranslation.normalized(source)) }
    try requireCapture(translated.panel.currentDraft == source,
                       "Translate lost a captured paragraph in the editable draft")
    try requireCapture(translated.paragraphRequests.count == 1
                       && translated.paragraphRequests[0].sourceText == source
                       && !translated.paragraphRequests[0].includeSegmentation
                       && !translated.paragraphRequests[0].includeReadings,
                       "Translate failed to request only the full source paragraph")
    try requireCapture(translated.transport.requests.isEmpty && translated.enrichmentCount == 0,
                       "Translate contacted a dictionary transport or enriched a word")
    try requireCapture(AppStateStore(defaults: translated.defaults).dictionaryPresentationMode == .translate,
                       "Translate mode was not persisted")
    translated.selected = "Singleword"
    translated.coordinator.start()
    try await waitUntil { translated.labels.contains("Translated: Singleword") }
    try requireCapture(translated.transport.requests.isEmpty && translated.paragraphRequests.count == 2,
                       "A single-word capture in Translate launched dictionary work")
    translated.coordinator.restoreHistory(.init(id: UUID(), query: source,
                                                 sourceLanguage: .automatic,
                                                 targetLanguage: .japanese,
                                                 lookedUpAt: Date()))
    try await waitUntil { translated.paragraphRequests.count == 3 }
    try requireCapture(translated.paragraphRequests.last?.sourceText == source
                       && translated.paragraphRequests.last?.targetLanguage == .japanese,
                       "History restore failed to translate its full source into its saved target")
    try await waitUntil { translated.labels.contains("Translated: " + DictionaryParagraphTranslation.normalized(source)) }
    let beforeCache = translated.paragraphRequests.count
    try translated.click("Switch to Dictionary")
    try translated.click("Switch to Translate")
    try requireCapture(translated.paragraphRequests.count == beforeCache,
                       "Reentering a completed unchanged Translate request ignored its cache")
    translated.clean()

    let draft = CaptureFixture(selected: "original", useAI: true)
    defer { draft.clean() }
    try await draft.start()
    draft.lookupField?.stringValue = "Unsubmitted draft\nwith its final line."
    try draft.click("Switch to Translate")
    try await waitUntil { draft.labels.contains("Translated: Unsubmitted draft with its final line.") }
    try requireCapture(draft.paragraphRequests.last?.sourceText == "Unsubmitted draft\nwith its final line.",
                       "Mode switch used the submitted query instead of the draft")
    try draft.click("Switch to Dictionary")
    try requireCapture(draft.panel.currentDraft == "Unsubmitted draft\nwith its final line.",
                       "Returning to Dictionary discarded the Translate source")
    draft.clean()

    let missing = CaptureFixture(selected: "Hello", useAI: false, presentationMode: .translate)
    defer { missing.clean() }
    try await missing.start()
    try requireCapture(missing.labels.contains { $0.contains("Set up an AI provider") }
                       && missing.lookupField?.stringValue == "Hello",
                       "Missing AI configuration did not leave an editable source and explanation")
    try missing.click("Switch to Dictionary")
    try await waitUntil { !missing.transport.requests.isEmpty }
    missing.clean()

    let failed = CaptureFixture(selected: "Retry this", useAI: true, presentationMode: .translate)
    defer { failed.clean() }
    failed.failContext = true
    try await failed.start()
    try await waitUntil { failed.controls.contains { $0.accessibilityIdentifier() == "dictionary.status.retry" } }
    try requireCapture(!failed.labels.contains("Translated: Retry this"),
                       "Failed translation showed an empty success")
    failed.failContext = false
    try failed.click("Retry translation")
    try await waitUntil { failed.labels.contains("Translated: Retry this") }
    failed.clean()

    for malformed in [false, true] {
        let invalid = CaptureFixture(selected: "Keep this source", useAI: true, presentationMode: .translate)
        defer { invalid.clean() }
        invalid.missingParagraphTranslation = !malformed
        invalid.malformedParagraphResponse = malformed
        try await invalid.start()
        try await waitUntil { invalid.controls.contains { $0.accessibilityIdentifier() == "dictionary.status.retry" } }
        try requireCapture(invalid.lookupField?.stringValue == "Keep this source"
                           && !invalid.labels.contains("Translated: Keep this source"),
                           "An invalid response lost the source or appeared successful")
        invalid.missingParagraphTranslation = false
        invalid.malformedParagraphResponse = false
        try invalid.click("Retry translation")
        try await waitUntil { invalid.labels.contains("Translated: Keep this source") }
        try requireCapture(invalid.paragraphRequests.count == 2,
                           "Invalid response retry did not perform a new translation request")
        invalid.clean()
    }

    let script = CaptureFixture(selected: "I cannot continue.", useAI: true,
                                targetLanguage: "zh", presentationMode: .translate)
    defer { script.clean() }
    script.paragraphOutputForRequest = { context in
        if context.targetLanguage == .japanese { return "日本語の漢字は変換しません。" }
        // Return the opposite script so the displayed target enforcement is tested.
        return context.targetLanguage?.rawValue == "zh-hant" ? "我现在无法继续。" : "我現在無法繼續。"
    }
    try await script.start()
    try await waitUntil { script.labels.contains("我现在无法继续。") }
    try script.chooseLanguage("zh-hant")
    try await waitUntil { script.labels.contains("我現在無法繼續。") }
    try script.chooseLanguage("ja")
    try await waitUntil { script.labels.contains("日本語の漢字は変換しません。") }
    try requireCapture(script.paragraphRequests.count == 3 && script.transport.requests.isEmpty,
                       "Target script changes reused the wrong translation or launched dictionary lookup")
    try script.chooseLanguage("zh")
    try requireCapture(script.labels.contains("我现在无法继续。") && script.paragraphRequests.count == 3,
                       "The script-specific paragraph cache missed or displayed the wrong script")
    script.clean()

    let delayed = CaptureFixture(selected: "Old request", useAI: true, presentationMode: .translate)
    defer { delayed.clean() }
    delayed.paragraphDelay = 400_000_000
    delayed.ignoreParagraphCancellation = true
    try await delayed.start()
    try await waitUntil { delayed.paragraphRequests.count == 1 }
    delayed.paragraphDelay = 40_000_000
    try delayed.submit("New request")
    try await waitUntil { delayed.labels.contains("Translated: New request") }
    try await waitUntil { delayed.paragraphCompletions.count == 2 }
    try requireCapture(delayed.labels.contains("Translated: New request")
                       && !delayed.labels.contains("Translated: Old request"),
                       "A delayed old paragraph replaced a new query")
    delayed.clean()

    let targetRace = CaptureFixture(selected: "Same query", useAI: true, presentationMode: .translate)
    defer { targetRace.clean() }
    targetRace.paragraphDelay = 400_000_000
    targetRace.ignoreParagraphCancellation = true
    targetRace.paragraphOutputForRequest = { "Target: " + ($0.targetLanguage?.rawValue ?? "en") }
    try await targetRace.start()
    try await waitUntil { targetRace.paragraphRequests.count == 1 }
    targetRace.paragraphDelay = 40_000_000
    try targetRace.chooseLanguage("es")
    try await waitUntil { targetRace.labels.contains("Target: es") }
    try await waitUntil { targetRace.paragraphCompletions.count == 2 }
    try requireCapture(targetRace.labels.contains("Target: es") && !targetRace.labels.contains("Target: en"),
                       "A delayed old target overwrote the selected translation language")
    targetRace.clean()

    let modeRace = CaptureFixture(selected: "hello", useAI: true, presentationMode: .translate)
    defer { modeRace.clean() }
    modeRace.paragraphDelay = 300_000_000
    modeRace.ignoreParagraphCancellation = true
    try await modeRace.start()
    try await waitUntil { modeRace.paragraphRequests.count == 1 }
    try modeRace.click("Switch to Dictionary")
    try await waitUntil { modeRace.labels.contains("fixture definition for hello") }
    try await waitUntil { modeRace.paragraphCompletions.count == 1 }
    try requireCapture(modeRace.controls.contains { $0.accessibilityLabel() == "Switch to Translate" }
                       && !modeRace.labels.contains("Translated: hello"),
                       "A late Translate response overwrote Dictionary after switching back")
    modeRace.clean()

    let dictionaryRace = CaptureFixture(selected: "hello",
        transport: .init(delay: 350_000_000, ignoresCancellation: true), useAI: true)
    defer { dictionaryRace.clean() }
    dictionaryRace.paragraphDelay = 40_000_000
    try await dictionaryRace.start()
    try await waitUntil { !dictionaryRace.transport.requests.isEmpty }
    try dictionaryRace.click("Switch to Translate")
    try await waitUntil { dictionaryRace.labels.contains("Translated: hello") }
    try await Task.sleep(nanoseconds: 400_000_000)
    try requireCapture(dictionaryRace.labels.contains("Translated: hello")
                       && !dictionaryRace.labels.contains("fixture definition for hello"),
                       "A canceled Dictionary response overwrote Translate")
    dictionaryRace.clean()

    for disable in [false, true] {
        let closed = CaptureFixture(selected: "Pending source", useAI: true, presentationMode: .translate)
        defer { closed.clean() }
        closed.paragraphDelay = 200_000_000
        closed.ignoreParagraphCancellation = true
        try await closed.start()
        try await waitUntil { closed.paragraphRequests.count == 1 }
        if disable { closed.coordinator.releaseResources() } else { closed.coordinator.cancel() }
        try await waitUntil { closed.paragraphCompletions.count == 1 }
        try requireCapture(!closed.panel.isVisible,
                           "A delayed translation reopened a closed or disabled panel")
        closed.clean()
    }
    print("PASS persistent full-input Translate, draft, cache, history, retry, scripts, and delayed-response cancellation")
}

@MainActor
func dictionaryCaptureChecks() async throws {
    let cases: [(String?, String, Data?, Bool, Bool, [String], String?)] = [
        ("hello", "ignored", Data([1]), true, true, ["selection"], "hello"),
        ("  \n", "hola", Data([1]), true, true, ["selection", "screenshot", "OCR"], "hola"),
        (nil, "  \n", Data([1]), true, true, ["selection", "screenshot", "OCR"], nil),
        (nil, "ignored", nil, true, true, ["selection", "screenshot"], nil),
        (nil, "ignored", nil, false, false, [], nil),
        (nil, "你好", Data([1]), false, true, ["screenshot", "OCR"], "你好"),
    ]
    for (selected, recognized, screenshot, accessibility, screen, events, query) in cases {
        let fixture = CaptureFixture(selected: selected, recognized: recognized, screenshot: screenshot,
                                     accessibility: accessibility, screen: screen)
        defer { fixture.clean() }
        try await fixture.start()
        try requireCapture(fixture.events == events, "Fallback stages were not exclusive/in order: \(fixture.events)")
        try requireCapture(fixture.lookupField?.stringValue == (query ?? ""), "Captured text did not reach lookup field")
        if query == nil {
            try requireCapture(fixture.window?.firstResponder is NSTextView, "Manual fallback did not focus typing")
            if !accessibility {
                try requireCapture(fixture.labels.contains { $0.contains("Accessibility") },
                                   "A missing selection permission was not explained in manual lookup")
                try requireCapture(fixture.controls.contains {
                    $0.accessibilityLabel() == "Open capture permissions and settings"
                }, "Missing Accessibility permission did not offer its settings link")
            }
        }
        fixture.clean()
    }
    let error = CaptureFixture(selected: nil)
    defer { error.clean() }
    error.captureError = true
    try await error.start()
    try requireCapture(error.events == ["selection", "screenshot"] && error.lookupField?.stringValue == "",
                       "Capture failure must stop at focused manual input")
    try requireCapture(error.labels.contains { $0.contains("capture failed") }, "Missing capture-error explanation")
    error.clean()
    let miss = CaptureFixture(selected: "unknownfixtureword", transport: .init(status: 404))
    defer { miss.clean() }
    try await miss.start()
    try await waitUntil { !miss.transport.requests.isEmpty }
    try requireCapture(miss.events == ["selection"], "Dictionary miss started another input stage")
    miss.clean()
    let canceled = CaptureFixture(selected: "late")
    defer { canceled.clean() }
    canceled.selectionDelay = 80_000_000
    canceled.coordinator.start()
    try await waitUntil { canceled.events == ["selection"] }
    canceled.coordinator.cancel()
    try await Task.sleep(nanoseconds: 140_000_000)
    try requireCapture(!canceled.panel.isVisible && canceled.events == ["selection"],
                       "Canceled capture reopened the panel or advanced to OCR")
    print("PASS exclusive selection → screenshot → OCR → typing fallbacks and cancellation")

    let reopened = CaptureFixture(selected: "old lookup")
    defer { reopened.clean() }
    try await reopened.start()
    _ = reopened.coordinator.consumePanelActivation()
    reopened.selected = "new selected text"
    reopened.selectionDelay = 50_000_000
    reopened.coordinator.toggle()
    reopened.coordinator.toggle()
    try await waitUntil { reopened.lookupField?.stringValue == "new selected text" }
    try requireCapture(reopened.events == ["selection", "selection"],
                       "Reopening a background Dictionary panel skipped the new selection")
    try requireCapture(reopened.coordinator.consumePanelActivation(),
                       "Capturing a new selection did not reactivate the background Dictionary panel")
    // Without a new selection, reopening preserves an unfinished manual draft
    // and resumes the panel instead of interrupting it with another crop.
    reopened.lookupField?.stringValue = "unfinished draft"
    reopened.selected = nil
    reopened.coordinator.toggle()
    try await waitUntil { reopened.events.count == 3 }
    try requireCapture(reopened.lookupField?.stringValue == "unfinished draft",
                       "Reopening without a selection discarded the current draft")
    try requireCapture(reopened.events == ["selection", "selection", "selection"],
                       "Resuming the existing panel unexpectedly opened screenshot selection")
    reopened.clean()
    print("PASS background panel captures a new selection before taking focus and preserves an unsubmitted draft")

    let sentence = CaptureFixture(selected: "I enjoy learning languages.", useAI: true, targetLanguage: "zh")
    defer { sentence.clean() }
    try await sentence.start()
    try requireCapture(sentence.historyStore.items.count == 1,
                       "A submitted sentence should create one history item")
    let sentenceHistory = sentence.historyStore.items[0]
    try sentence.click("Next sentence token")
    try sentence.click("Next sentence token")
    try await waitUntil { sentence.labels.contains("Translated: I enjoy learning languages.") }
    try requireCapture(sentence.contexts.count == 1, "Word navigation restarted sentence translation")
    try requireCapture(sentence.historyStore.items.count == 1,
                       "Word navigation created a duplicate history item")
    try sentence.click("Previous sentence token")
    try requireCapture(sentence.labels.contains("Translated: I enjoy learning languages."), "Navigation removed sentence translation")
    sentence.coordinator.restoreHistory(DictionaryPanelHistoryItem(
        id: sentenceHistory.id,
        query: sentenceHistory.query,
        sourceLanguage: sentenceHistory.sourceLanguage,
        detectedSourceLanguage: sentenceHistory.detectedSourceLanguage,
        targetLanguage: sentenceHistory.targetLanguage,
        lookedUpAt: sentenceHistory.lookedUpAt
    ))
    try await waitUntil { sentence.lookupField?.stringValue == sentenceHistory.query }
    try requireCapture(sentence.events == ["selection"],
                       "History selection re-entered the capture fallback chain")
    try requireCapture(sentence.historyStore.items.count == 1,
                       "Reopening history created a duplicate history item")
    try sentence.submit("Me gusta aprender idiomas.")
    try await waitUntil { sentence.labels.contains("Translated: Me gusta aprender idiomas.") }
    try requireCapture(sentence.contexts.count == 2, "New query reused old sentence translation")
    try requireCapture(sentence.historyStore.items.count == 2,
                       "A distinct query was not added to history")
    sentence.coordinator.cancel()
    try await Task.sleep(nanoseconds: 220_000_000)
    try requireCapture(!sentence.panel.isVisible, "Late lookup reopened dismissed panel")
    print("PASS one sentence translation per query, retained while navigating, and no stale UI after close")

    let retryHistory = CaptureFixture(selected: "retry-history", transport: .init(status: 429))
    defer { retryHistory.clean() }
    try await retryHistory.start()
    try await waitUntil { retryHistory.controls.contains { $0.accessibilityLabel() == "Retry dictionary lookup" } }
    try requireCapture(retryHistory.historyStore.items.count == 1,
                       "Retry fixture did not record its initial lookup")
    try retryHistory.click("Retry dictionary lookup")
    try await waitUntil { retryHistory.transport.requests.count >= 2 }
    try requireCapture(retryHistory.historyStore.items.count == 1,
                       "Retry created a duplicate history item")
    retryHistory.clean()
    print("PASS history records once per query, reopens complete sentences, and excludes retries")

    let staleHistory = CaptureFixture(
        selected: "staleold",
        transport: .init(delay: 180_000_000, ignoresCancellation: true)
    )
    defer { staleHistory.clean() }
    try await staleHistory.start()
    try await waitUntil {
        staleHistory.historyStore.items.count == 1
            && !staleHistory.transport.requests.isEmpty
    }
    let staleItem = staleHistory.historyStore.items[0]
    staleHistory.coordinator.restoreHistory(DictionaryPanelHistoryItem(
        id: staleItem.id,
        query: staleItem.query,
        sourceLanguage: staleItem.sourceLanguage,
        detectedSourceLanguage: staleItem.detectedSourceLanguage,
        targetLanguage: staleItem.targetLanguage,
        lookedUpAt: staleItem.lookedUpAt
    ))
    try staleHistory.submit("stalenew")
    try await waitUntil {
        staleHistory.transport.requests.contains { $0.hasSuffix("/stalenew") }
    }
    try await waitUntil {
        staleHistory.labels.contains("fixture definition for stalenew")
    }
    try requireCapture(
        !staleHistory.labels.contains("fixture definition for staleold"),
        "A canceled history lookup replaced the newer query"
    )
    try requireCapture(staleHistory.historyStore.items.count == 2,
                       "History restore/new lookup recorded an unexpected number of rows")
    print("PASS canceled history responses cannot overwrite a newer query")
    staleHistory.clean()

    let cleared = CaptureFixture(
        selected: "clearold",
        transport: .init(delay: 180_000_000, ignoresCancellation: true)
    )
    defer { cleared.clean() }
    try await cleared.start()
    try await waitUntil {
        !cleared.transport.requests.isEmpty
    }
    cleared.coordinator.clearLookup()
    try await Task.sleep(nanoseconds: 260_000_000)
    try requireCapture(cleared.lookupField?.stringValue == "",
                       "Clear did not restore an empty lookup field")
    try requireCapture(!cleared.labels.contains("fixture definition for clearold"),
                       "A late response restored a cleared lookup")
    print("PASS clearing a lookup cancels late dictionary responses")
    // The fixture's deferred cleanup intentionally runs at scope exit, but
    // the next cases need a single visible Dictionary window so their labels
    // cannot be read from the just-cleared fixture.
    cleared.clean()

    let activeFirst = CaptureFixture(selected: "I enjoy learning languages.")
    defer { activeFirst.clean() }
    try await activeFirst.start()
    try await waitUntil { !activeFirst.transport.requests.isEmpty }
    try requireCapture(activeFirst.transport.requests.first?.hasSuffix("/I") == true,
                       "Adjacent prefetch ran before the active word")
    activeFirst.clean()
    let inflection = CaptureFixture(selected: "went")
    defer { inflection.clean() }
    try await inflection.start()
    try await waitUntil { !inflection.transport.requests.isEmpty }
    try requireCapture(inflection.transport.requests.first?.hasSuffix("/go") == true,
                       "Single-word inflection did not resolve to a dictionary lemma")
    inflection.clean()

    for (query, isSentence) in [("你好", false), ("食べる", false), ("图书馆", false),
                                ("我喜欢学习中文", true), ("明日は図書館で勉強します", true)] {
        let cjk = CaptureFixture(selected: query)
        defer { cjk.clean() }
        try await cjk.start()
        try requireCapture(cjk.controls.contains(where: { ($0 as? NSTextView)?.accessibilityLabel() == "Sentence source" }) == isSentence,
                           "CJK term/sentence classification failed for \(query): \(cjk.labels), events=\(cjk.events)")
        if !isSentence {
            try await waitUntil { !cjk.transport.requests.isEmpty }
            try requireCapture(cjk.transport.requests.first?.hasSuffix("/" + query) == true,
                               "Complete term was replaced with its first token: \(cjk.transport.requests)")
        }
        cjk.clean()
    }

    // Automatic mixed-script tokenization must route each token through its
    // own language. The fixture also returns a deliberately weak AI split of
    // 参考; the coordinator must reject it and keep the native compound so
    // lookup, enrichment, and speech all continue to use the complete word.
    let mixedSegmentation = [
        DictionaryToken(
            text: "annual",
            sourceRange: NSRange(location: 0, length: 6),
            language: .english
        ),
        DictionaryToken(
            text: "report",
            sourceRange: NSRange(location: 7, length: 6),
            language: .english
        ),
        DictionaryToken(
            text: "参",
            sourceRange: NSRange(location: 14, length: 1),
            language: .chinese
        ),
        DictionaryToken(
            text: "考",
            sourceRange: NSRange(location: 15, length: 1),
            language: .chinese
        ),
    ]
    let mixed = CaptureFixture(
        selected: "annual report 参考",
        useAI: true,
        contextSegmentation: mixedSegmentation
    )
    defer { mixed.clean() }
    try await mixed.start()
    try await waitUntil { mixed.transport.requests.contains { $0.hasSuffix("/en/annual") } }
    try mixed.click("Next sentence token")
    try mixed.click("Next sentence token")
    try await waitUntil {
        mixed.transport.requests.contains { $0.hasSuffix("/zh/参考") }
    }
    try requireCapture(
        !mixed.transport.requests.contains(where: { $0.hasSuffix("/en/参考") })
            && !mixed.transport.requests.contains(where: { $0.hasSuffix("/zh/参") })
            && !mixed.transport.requests.contains(where: { $0.hasSuffix("/zh/考") }),
        "Mixed-script lookup lost the token language or split 参考: \(mixed.transport.requests)"
    )
    try await waitUntil { mixed.enrichmentLanguages.contains("zh") }
    print("PASS mixed-script token languages route lookup, AI enrichment, and compound preservation")
    mixed.clean()

    // A coherent AI response must keep the native lemma on an unchanged
    // English span. Without that preservation, a second focused lookup is
    // issued for the surface form after AI segmentation (went instead of go).
    let mixedLemmaSegmentation = [
        DictionaryToken(
            text: "went",
            sourceRange: NSRange(location: 0, length: 4),
            language: .english
        ),
        DictionaryToken(
            text: "参考",
            sourceRange: NSRange(location: 5, length: 2),
            language: .chinese
        ),
    ]
    let mixedLemma = CaptureFixture(
        selected: "went 参考",
        useAI: true,
        contextSegmentation: mixedLemmaSegmentation
    )
    defer { mixedLemma.clean() }
    try await mixedLemma.start()
    try await waitUntil {
        mixedLemma.contexts.count == 1
            && mixedLemma.transport.requests.contains { $0.hasSuffix("/en/go") }
    }
    try await Task.sleep(nanoseconds: 220_000_000)
    try requireCapture(
        !mixedLemma.transport.requests.contains(where: { $0.hasSuffix("/en/went") }),
        "AI segmentation discarded the native English lemma: (mixedLemma.transport.requests)"
    )
    mixedLemma.clean()
    print("PASS AI segmentation preserves native lemmas on unchanged mixed-script spans")

    let splitReference: DictionaryCoordinator.NativeRefinement = { tokens in
        try? await Task.sleep(nanoseconds: 320_000_000)
        var refined: [DictionaryNativeToken] = []
        for token in tokens {
            guard token.text == "参考",
                  token.language?.canonicalCode == "zh"
            else {
                refined.append(token)
                continue
            }
            refined.append(DictionaryNativeToken(
                text: "参",
                utf16Range: NSRange(location: token.utf16Range.location, length: 1),
                lemma: "参",
                isPunctuation: false,
                isWhitespace: false,
                language: .chinese
            ))
            refined.append(DictionaryNativeToken(
                text: "考",
                utf16Range: NSRange(location: token.utf16Range.location + 1, length: 1),
                lemma: "考",
                isPunctuation: false,
                isWhitespace: false,
                language: .chinese
            ))
        }
        return refined
    }

    let canceledNative = CaptureFixture(
        selected: "annual 参考",
        nativeRefinement: splitReference
    )
    defer { canceledNative.clean() }
    try await canceledNative.start()
    try await waitUntil { !canceledNative.transport.requests.isEmpty }
    canceledNative.coordinator.cancel()
    try await Task.sleep(nanoseconds: 420_000_000)
    try requireCapture(
        !canceledNative.panel.isVisible,
        "Canceled native compound refinement reopened the Dictionary panel"
    )
    canceledNative.clean()
    print("PASS canceled native compound refinement cannot reopen a closed lookup")

    let coherentSegmentation = [
        DictionaryToken(
            text: "annual",
            sourceRange: NSRange(location: 0, length: 6),
            language: .english
        ),
        DictionaryToken(
            text: "参考",
            sourceRange: NSRange(location: 7, length: 2),
            language: .chinese
        ),
    ]
    let aiPrecedence = CaptureFixture(
        selected: "annual 参考",
        useAI: true,
        contextSegmentation: coherentSegmentation,
        nativeRefinement: splitReference
    )
    defer { aiPrecedence.clean() }
    try await aiPrecedence.start()
    try await waitUntil { aiPrecedence.contexts.count == 1 }
    try aiPrecedence.click("Next sentence token")
    try await waitUntil {
        aiPrecedence.transport.requests.contains { $0.hasSuffix("/zh/参考") }
    }
    try await Task.sleep(nanoseconds: 420_000_000)
    try requireCapture(
        !aiPrecedence.transport.requests.contains(where: { $0.hasSuffix("/zh/参") })
            && !aiPrecedence.transport.requests.contains(where: { $0.hasSuffix("/zh/考") }),
        "Late native refinement overwrote coherent AI compound segmentation: \(aiPrecedence.transport.requests)"
    )
    aiPrecedence.clean()
    print("PASS coherent AI compound segmentation wins over a late native refinement")

    let idiom = CaptureFixture(selected: "annual 画蛇添足")
    defer { idiom.clean() }
    try await idiom.start()
    try await waitUntil { idiom.transport.requests.contains { $0.hasSuffix("/en/annual") } }
    try idiom.click("Next sentence token")
    try await waitUntil {
        idiom.transport.requests.contains { $0.hasSuffix("/zh/画蛇添足") }
    }
    try requireCapture(
        !idiom.transport.requests.contains(where: { $0.hasSuffix("/zh/画") })
            && !idiom.transport.requests.contains(where: { $0.hasSuffix("/zh/蛇") })
            && !idiom.transport.requests.contains(where: { $0.hasSuffix("/zh/添") })
            && !idiom.transport.requests.contains(where: { $0.hasSuffix("/zh/足") }),
        "Four-character idiom was fragmented: \(idiom.transport.requests)"
    )
    idiom.clean()
    print("PASS Chinese dictionary compounds and four-character idioms stay whole")

    for status in [429, 0] {
        let failure = CaptureFixture(selected: "hello", transport: .init(status: status))
        defer { failure.clean() }
        try await failure.start()
        try await waitUntil { failure.controls.contains { $0.accessibilityLabel() == "Retry dictionary lookup" } }
        try requireCapture(failure.labels.contains { $0.contains("hello") }, "Network error discarded native definition")
        failure.clean()
    }
    print("PASS complete CJK terms, unspaced sentences, offline fallback, rate limiting, and retry")
    let manySenses = CaptureFixture(selected: "review", transport: .init(senseCount: 12))
    defer { manySenses.clean() }
    try await manySenses.start()
    try await waitUntil { manySenses.controls.contains { ($0 as? NSButton)?.title == "Show 11 more meanings" } }
    guard let disclosure = manySenses.controls.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "dictionary.meanings.disclosure" }) else {
        throw CaptureCheckFailure(description: "All dictionary senses disclosure is missing")
    }
    _ = NSApp.sendAction(disclosure.action!, to: disclosure.target, from: disclosure)
    try requireCapture(manySenses.labels.contains("deep nested sense for review")
                       && manySenses.labels.contains("fixture definition 12 for review"),
                       "Coordinator discarded senses before the view could expand them")
    manySenses.clean()
    let readingFixture = CaptureFixture(selected: "pronunciationfixtureword", useAI: true)
    defer { readingFixture.clean() }
    readingFixture.enrichmentReadings = ["prəˌnʌnsiˈeɪʃən"]
    try await readingFixture.start()
    func readingRow(_ fixture: CaptureFixture) -> NSTextField? {
        fixture.controls.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "dictionary.pronunciation" }
    }
    try await waitUntil { readingRow(readingFixture)?.stringValue.contains("· AI") == true }
    try requireCapture(!readingFixture.labels.contains { $0.hasPrefix("AI reading:") }, "Coordinator appended AI reading to footer")
    let targetMenu = readingFixture.controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "dictionary.target" }!
    targetMenu.selectItem(withTitle: DictionaryTargetLanguage.chinese.displayName)
    _ = NSApp.sendAction(targetMenu.action!, to: targetMenu.target, from: targetMenu)
    try await waitUntil { readingFixture.enrichmentCount >= 2 && readingRow(readingFixture)?.stringValue.contains("· AI") == true }
    targetMenu.selectItem(withTitle: DictionaryTargetLanguage.english.displayName)
    _ = NSApp.sendAction(targetMenu.action!, to: targetMenu.target, from: targetMenu)
    try await waitUntil { readingRow(readingFixture)?.stringValue.contains("· AI") == true }
    try requireCapture(AppStateStore(defaults: readingFixture.defaults).dictionaryTargetLanguage == "en",
                       "Direct target menu did not persist target changes")
    readingFixture.clean()
    let dictionaryReading = CaptureFixture(selected: "readingfixture", transport: .init(dictionaryReading: "dictionary reading"), useAI: true)
    defer { dictionaryReading.clean() }
    dictionaryReading.enrichmentReadings = ["different AI reading"]
    try await dictionaryReading.start()
    try await waitUntil { dictionaryReading.enrichmentCount > 0 && readingRow(dictionaryReading) != nil }
    try requireCapture(readingRow(dictionaryReading)?.stringValue == "dictionary reading",
                       "AI enrichment replaced or relabeled the dictionary pronunciation")
    dictionaryReading.clean()
    print("PASS all dictionary senses and nested senses, AI reading provenance through target changes/cache, and dictionary reading preference")
    let contextError = CaptureFixture(selected: "I enjoy learning languages.", transport: .init(delay: 100_000_000), useAI: true)
    defer { contextError.clean() }
    contextError.failContext = true
    try await contextError.start()
    try await waitUntil { contextError.labels.contains { $0.contains("fixture definition") } }
    try requireCapture(contextError.labels.contains { $0.contains("fixture context failure") },
                       "A successful dictionary response erased the sentence translation failure")
    print("PASS sentence AI error remains retryable beside a usable dictionary entry")
}

@MainActor
func dictionaryScreenshotChecks() async throws {
    let png = try DictionaryNativeChecks.imageWithText("screenshot fixture")
    let changeCount = NSPasteboard.general.changeCount
    var paths: [String] = []
    let success = ScreenshotService(processRunner: { arguments in
        try requireCapture(!arguments.contains("-c"), "Dictionary screenshot must not write clipboard")
        let path = arguments.last!
        paths.append(path)
        try png.write(to: URL(fileURLWithPath: path))
        return 0
    })
    let capture = try await success.captureSelection(preserveClipboard: true)
    try requireCapture(capture?.pngData == png, "Temporary screenshot was not loaded into memory")
    try requireCapture(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "Temporary screenshot was retained")
    let escape = ScreenshotService(processRunner: { arguments in
        paths.append(arguments.last!)
        return 1
    })
    let escaped = try await escape.captureSelection(preserveClipboard: true)
    try requireCapture(escaped == nil, "Screenshot Escape must return no image")
    let error = ScreenshotService(processRunner: { arguments in
        paths.append(arguments.last!)
        try png.write(to: URL(fileURLWithPath: arguments.last!))
        throw CaptureCheckFailure(description: "fixture process failure")
    })
    do {
        _ = try await error.captureSelection(preserveClipboard: true)
        throw CaptureCheckFailure(description: "Screenshot process error was swallowed")
    } catch let error as CaptureCheckFailure {
        try requireCapture(error.description == "fixture process failure", "Unexpected screenshot error")
    }
    try requireCapture(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "Failed screenshot left a temporary file")
    try requireCapture(NSPasteboard.general.changeCount == changeCount, "Screenshot changed the clipboard")
    print("PASS clipboard-preserving temporary screenshots and cleanup on success, Escape, and failure")
}
