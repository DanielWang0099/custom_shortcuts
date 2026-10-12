import AIShortcutsCore
import AppKit
import AVFoundation
import Foundation

private struct DictionaryCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DictionaryCheckFailure(description: message) }
}

@main
struct DictionaryNativeChecks {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        do {
            if CommandLine.arguments.contains("--gutter-only") {
                try dictionaryPanelScrollerGutterChecks()
                print("PASS focused native dictionary scroller checks")
                print("All native dictionary checks passed.")
                return
            }
            if CommandLine.arguments.contains("--placement-only") {
                try dictionaryPanelMovedPlacementChecks()
                print("PASS focused native dictionary placement checks")
                print("All native dictionary checks passed.")
                return
            }
            try languageAndRanges()
            try preferences()
            try await nativeOCR()
            try panelRendering()
            try dictionaryPanelLayoutChecks()
            try dictionaryPanelTranslationChecks()
            try dictionaryPanelScrollerGutterChecks()
            try dictionaryPanelMovedPlacementChecks()
            try dictionaryPanelCompoundChecks()
            try dictionaryPanelHistoryChecks()
            try await dictionaryActivationChecks()
            try await dictionaryScreenshotChecks()
            try await dictionaryCaptureChecks()
            try await dictionaryTranslationChecks()
            try await dictionaryChineseScriptChecks()
            if CommandLine.arguments.contains("--live") {
                try await liveDictionary()
            }
            if CommandLine.arguments.contains("--live-ai") {
                try await dictionaryLiveAIChecks()
            }
            print("All native dictionary checks passed.")
        } catch {
            print("FAIL native dictionary: \(error)")
            exit(EXIT_FAILURE)
        }
    }

    static func languageAndRanges() throws {
        let samples: [(String, String)] = [
            ("I enjoy learning languages.", "en"),
            ("Me gusta aprender idiomas.", "es"),
            ("我喜欢学习中文。", "zh"),
            ("明日は図書館で勉強します。", "ja"),
            ("Bonjour, je voudrais apprendre le français.", "fr"),
        ]
        for (text, language) in samples {
            let detected = DictionaryLanguageService.detect(text)
            try check(detected.rawValue == language, "Incorrect detected language for \(text): \(detected.rawValue)")
            let tokens = DictionaryLanguageService.tokenize(text, language: detected)
            try check(tokens.map(\.text).joined() == text, "Tokenization changed source text")
            for token in tokens {
                try check((text as NSString).substring(with: token.utf16Range) == token.text,
                          "Token UTF-16 range does not match source")
            }
        }
        try check(DictionaryLanguageService.detect("无法") == .chinese,
                  "Simplified selection was not labeled Simplified")
        try check(DictionaryLanguageService.detect("無法") == .traditionalChinese,
                  "Traditional selection was not labeled Traditional")
        try check(DictionaryLanguageService.detect("中文") == .chinese,
                  "Ambiguous Chinese did not default Simplified")
        try check(DictionaryLanguageService.detect("无法", preferred: .traditionalChinese) == .traditionalChinese,
                  "Explicit Traditional source was ignored")
        let traditionalTokens = DictionaryLanguageService.tokenize("無法筛选")
        try check(traditionalTokens.map(\.text).joined() == "無法筛选",
                  "Mixed Han scripts changed source text")
        for token in traditionalTokens {
            try check(("無法筛选" as NSString).substring(with: token.utf16Range) == token.text,
                      "Chinese script detection changed source ranges")
        }
        let repeated = "hello, hello!\n你好 👋🏽 食べる"
        let tokens = DictionaryLanguageService.tokenize(repeated)
        try check(tokens.map(\.text).joined() == repeated, "Repeated words/newlines/emoji lost in tokenization")
        let repeatedWords = tokens.filter { $0.text == "hello" }
        try check(repeatedWords.count == 2 && repeatedWords[0].utf16Range != repeatedWords[1].utf16Range,
                  "Repeated words need distinct source ranges")
        try check(!tokens.filter(\.isWord).contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "," },
                  "Punctuation mixed with whitespace became a dictionary word")
        let spanish = DictionaryLanguageService.tokenize("Me gusta aprender idiomas.\nMe gusta aprender japonés.", language: .spanish)
        try check(spanish.filter(\.isWord).count == 8, "Mixed punctuation/newline gaps became navigable words")
        try check(DictionaryLanguageService.detect("casa", preferred: .spanish) == .spanish,
                  "Source-language override was ignored")

        let mixed = DictionaryLanguageService.tokenize("中文English文件名")
        let mixedWords = mixed.filter(\.isWord)
        try check(mixedWords.map(\.text) == ["中文", "English", "文件名"],
                  "Mixed Chinese and English filename segmentation lost a compound")
        try check(mixedWords.map { $0.language?.canonicalCode } == ["zh", "en", "zh"],
                  "Automatic mixed-script token languages were not localized per run")

        let compounds = DictionaryLanguageService.tokenize(
            "参考资料 参考 画蛇添足 一举两得 一心一意",
            language: .chinese
        )
        try check(
            compounds.filter(\.isWord).map(\.text) ==
                ["参考资料", "参考", "画蛇添足", "一举两得", "一心一意"],
            "Exact Chinese dictionary compounds or idioms were not recovered"
        )
        try check(
            compounds.filter(\.isWord).allSatisfy { $0.language?.canonicalCode == "zh" },
            "Chinese compounds did not retain their source language"
        )
        let fastChinese = DictionaryLanguageService.tokenize(
            "一心一意",
            language: .chinese,
            dictionaryProbeLimit: 0
        )
        try check(
            fastChinese.map(\.text).joined() == "一心一意",
            "Fast Chinese tokenization changed the source text"
        )
        let refinedChinese = DictionaryLanguageService.refineChineseCompounds(
            in: fastChinese,
            dictionaryProbeLimit: 128
        )
        try check(
            refinedChinese.filter(\.isWord).map(\.text) == ["一心一意"],
            "The bounded background Chinese refinement did not recover an idiom"
        )

        let traditional = DictionaryLanguageService.tokenize(
            "資產 參考 腳本 畫蛇添足 一舉兩得",
            language: .chinese
        )
        try check(
            traditional.filter(\.isWord).map(\.text) ==
                ["資產", "參考", "腳本", "畫蛇添足", "一舉兩得"],
            "Traditional Chinese compounds or idioms were split unexpectedly"
        )

        for text in ["我喜欢学习", "阿甲乙丙丁", "四字词语"] {
            let words = DictionaryLanguageService.tokenize(text, language: .chinese)
                .filter(\.isWord)
            try check(words.map(\.text).joined() == text,
                      "Dictionary segmentation changed arbitrary Han text \(text)")
            try check(!words.contains { $0.text == text },
                      "Dictionary segmentation swallowed arbitrary full text \(text)")
        }

        let longHan = String(repeating: "阿甲乙丙丁", count: 80)
        let longTokens = DictionaryLanguageService.tokenize(longHan, language: .chinese)
        try check(longTokens.map(\.text).joined() == longHan,
                  "Bounded long-input segmentation changed the source")
        try check(longTokens.count > 1,
                  "Bounded long-input segmentation collapsed the entire OCR run")

        let automaticJapanese = DictionaryLanguageService.tokenize("食べる")
        try check(automaticJapanese.filter(\.isWord).map(\.text) == ["食べる"],
                  "Japanese Han plus kana was split at a script boundary")
        try check(automaticJapanese.filter(\.isWord).allSatisfy {
            $0.language?.canonicalCode == "ja"
        }, "Japanese mixed-script token lost its language metadata")

        let japaneseHanContext = DictionaryLanguageService.tokenize("図書館、学校で勉強します。")
        try check(
            japaneseHanContext.filter(\.isWord).allSatisfy {
                $0.language?.canonicalCode == "ja"
            },
            "Japanese Han runs separated by punctuation lost their language context"
        )

        let contractions = DictionaryLanguageService.tokenize(
            "I'm well-known",
            language: .english
        )
        try check(
            contractions.filter(\.isWord).map(\.text) == ["I'm", "well", "known"],
            "Latin contractions or hyphenated words were split before NLTokenizer"
        )

        let englishOverride = DictionaryLanguageService.tokenize(
            "中文English",
            language: .english
        )
        try check(
            englishOverride.filter(\.isWord).allSatisfy { $0.language?.canonicalCode == "en" },
            "Explicit English source override was not honored per token"
        )
        let chineseOverride = DictionaryLanguageService.tokenize(
            "English",
            language: .chinese
        )
        try check(
            chineseOverride.filter(\.isWord).allSatisfy { $0.language?.canonicalCode == "zh" },
            "Explicit Chinese source override was not honored for Latin text"
        )
        print("PASS native language detection and source ranges")
    }

    @MainActor
    static func preferences() throws {
        let name = "AIShortcuts.DictionaryChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppStateStore(defaults: defaults)
        try check(store.dictionaryPresentationMode == .dictionary, "Existing users must default to Dictionary mode")
        store.dictionaryPresentationMode = .translate
        try check(AppStateStore(defaults: defaults).dictionaryPresentationMode == .translate,
                  "Translate mode did not persist across state-store recreation")
        defaults.set("unknown-mode", forKey: "dictionaryPresentationMode.v1")
        try check(store.dictionaryPresentationMode == .dictionary, "An invalid saved mode did not fall back to Dictionary")
        try check(["en", "English"].contains(store.dictionaryTargetLanguage), "Default target is not English")
        store.dictionaryTargetLanguage = "es"
        try check(AppStateStore(defaults: defaults).dictionaryTargetLanguage == "es", "Target language did not persist")
        store.dictionaryTargetLanguage = "zh-hant"
        try check(AppStateStore(defaults: defaults).dictionaryTargetLanguage == "zh-hant", "Traditional target did not persist")
        store.dictionaryTargetLanguage = "zh"
        try check(DictionaryTargetLanguage(rawValue: AppStateStore(defaults: defaults).dictionaryTargetLanguage) == .chinese,
                  "Legacy zh target no longer resolves to Simplified")
        try check(store.enabledShortcutActions.contains(.dictionary), "Dictionary must be enabled by default")
        store.setShortcut(.dictionary, enabled: false)
        try check(!AppStateStore(defaults: defaults).enabledShortcutActions.contains(.dictionary), "Shortcut toggle did not persist")
        print("PASS dictionary preferences and default enablement")
    }

    @MainActor
    static func nativeOCR() async throws {
        let languages = DictionaryOCRService.supportedRecognitionLanguages()
        try check(languages.contains(where: { $0.hasPrefix("ja") }) && languages.contains(where: { $0.hasPrefix("zh") }),
                  "Vision has no CJK recognition languages")
        let samples = ["dictionary", "aprender idiomas", "你好世界", "図書館で食べる"]
        for sample in samples {
            let data = try imageWithText(sample)
            let result = try await DictionaryOCRService.recognizeText(from: data)
            let normalized = result.filter { !$0.isWhitespace }
            try check(normalized.contains(sample.filter { !$0.isWhitespace }), "OCR failed: \(sample) -> \(result)")
        }
        let blank = try await DictionaryOCRService.recognizeText(from: imageWithText(""))
        try check(blank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty screenshot produced OCR text")
        for code in ["en-US", "es-ES", "zh-CN", "ja-JP"] {
            try check(AVSpeechSynthesisVoice(language: code) != nil, "Missing native speech voice \(code)")
        }
        print("PASS local OCR and available pronunciation voices for four languages")
    }

    @MainActor
    static func imageWithText(_ text: String) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 180,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { throw DictionaryCheckFailure(description: "Cannot create OCR test image") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1000, height: 180).fill()
        (text as NSString).draw(at: NSPoint(x: 40, y: 65), withAttributes: [
            .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw DictionaryCheckFailure(description: "Cannot encode OCR test image")
        }
        return data
    }

    @MainActor
    static func panelRendering() throws {
        let panel = DictionaryPanelController(presentationMode: .offscreenTest)
        var dismissCount = 0
        var selectedWords: [String] = []
        var spoken: [DictionarySpeechRequest] = []
        panel.show(state: .empty, onSubmit: { _ in }, onSelectToken: { selectedWords.append($0.text) },
                   onSpeak: { spoken.append($0) }, onDismiss: { dismissCount += 1 })
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.accessibilityLabel() == "Dictionary" }),
              let content = window.contentView else {
            throw DictionaryCheckFailure(description: "Dictionary panel did not open")
        }
        let field = descendants(content).compactMap { $0 as? NSTextField }.first { $0.isEditable }
        try check(field != nil && (window.firstResponder is NSTextView || window.firstResponder === field),
                  "Manual input must receive keyboard focus")
        try savePreview(window, name: "manual")

        let word = DictionaryPanelWord(originalText: "食べる", headword: "食べる", partOfSpeech: "verb",
                                       phonetic: "[ta̠be̞ɾɯ̟]", reading: "たべる · taberu",
                                       meanings: [.init(definition: "to eat"), .init(definition: "to make a living")],
                                       examples: [.init(source: "ご飯を食べる", translation: "to eat a meal", language: .japanese),
                                                  .init(source: "彼は農業で食べている。", translation: "He makes a living through farming.", language: .japanese)],
                                       sourceName: "Wiktionary · CC BY-SA 4.0", sourceURL: URL(string: "https://en.wiktionary.org/wiki/食べる"))
        let wordState = DictionaryPanelViewState(query: "食べる", sourceLanguage: .automatic,
                                  detectedSourceLanguage: .japanese, mode: .word, word: word,
                                  attributionName: "FreeDictionaryAPI.com · Wiktionary · CC BY-SA 4.0",
                                  attributionURL: word.sourceURL)
        panel.update(state: wordState)
        try savePreview(window, name: "word")
        let speak = descendants(content).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Speak 食べる" }
        try check(speak?.target === panel, "Speaker button is not wired to controller")
        if let speak, let action = speak.action { _ = NSApp.sendAction(action, to: speak.target, from: speak) }
        try check(spoken.first?.language == .japanese, "Automatic source detection picked the wrong pronunciation voice")
        field?.currentEditor()?.string = "draft query"
        panel.update(state: wordState)
        try check(field?.currentEditor()?.string == "draft query", "Async result update erased typed query")

        let sentence = "Me gusta aprender idiomas.\nMe gusta aprender japonés."
        let native = DictionaryLanguageService.tokenize(sentence, language: .spanish)
        let panelTokens = native.map(DictionaryPanelToken.init(native:))
        let active = native.firstIndex(where: { $0.text == "aprender" }) ?? 0
        let sentenceWord = DictionaryPanelWord(
            originalText: "aprender",
            headword: "aprender",
            partOfSpeech: "verb",
            phonetic: "/a.pɾenˈdeɾ/",
            meanings: [.init(definition: "to learn")]
        )
        let sentenceState = DictionaryPanelViewState(
            query: sentence,
            sourceLanguage: .spanish,
            mode: .sentence,
            word: sentenceWord,
            sentence: .init(
                source: sentence,
                translation: "I like learning languages.\nI like learning Japanese.",
                tokens: panelTokens,
                activeTokenIndex: active
            )
        )
        panel.update(state: sentenceState)
        try savePreview(window, name: "sentence")
        let regularSize = window.frame.size
        window.setContentSize(NSSize(width: 380, height: regularSize.height))
        panel.update(state: sentenceState)
        content.layoutSubtreeIfNeeded()
        for control in descendants(content).filter({
            ["dictionary.header", "dictionary.source", "dictionary.history"].contains($0.accessibilityIdentifier())
        }) {
            try check(content.bounds.contains(control.convert(control.bounds, to: content)),
                      "Dictionary header overflows at 380 points")
        }
        try savePreview(window, name: "sentence-380")
        window.setContentSize(regularSize)
        panel.update(state: sentenceState)
        let texts = descendants(content).compactMap { $0 as? NSTextView }.filter { $0.frame.width > 20 && $0.frame.height > 20 }.map(\.string)
        try check(texts.contains(sentence), "Sentence display must preserve source spacing and newlines")
        try check(window.frame.width <= (window.screen?.visibleFrame.width ?? 10000), "Panel does not fit screen")

        let tallWord = DictionaryPanelWord(
            originalText: "aprender",
            headword: "aprender",
            partOfSpeech: "verb",
            meanings: [
                .init(definition: "to learn through study, practice, and repeated use in a real situation"),
                .init(definition: "to acquire knowledge through study and careful observation over time"),
                .init(definition: "to memorize or understand a new idea by working through examples"),
                .init(definition: "to find out by experience after trying something for yourself"),
                .init(definition: "to become able to do something through patient guided practice"),
                .init(definition: "to discover a fact or lesson from an event or conversation"),
                .init(definition: "to develop a skill gradually with feedback and deliberate repetition"),
                .init(definition: "to absorb a language pattern and use it naturally in context"),
            ],
            examples: [
                .init(source: "Aprendí mucho hoy gracias a los ejemplos y la práctica."),
                .init(source: "Seguimos aprendiendo juntos con paciencia y buenos materiales."),
            ]
        )
        let tallState = DictionaryPanelViewState(
            query: sentence,
            sourceLanguage: .spanish,
            mode: .sentence,
            word: tallWord,
            sentence: sentenceState.sentence
        )
        panel.update(state: tallState)
        content.layoutSubtreeIfNeeded()
        guard let scrollView = descendants(content).compactMap({ $0 as? NSScrollView }).first,
              let tallGeometry = sentenceGeometry(content, source: sentence)
        else {
            throw DictionaryCheckFailure(description: "Sentence source or scroll view is missing")
        }
        let bottom = max(1, scrollView.documentView!.frame.height - scrollView.contentView.bounds.height - 1)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try check(scrollView.contentView.bounds.origin.y > 0, "Tall dictionary entry did not produce a scrollable body")
        guard let scrolledTallGeometry = sentenceGeometry(content, source: sentence) else {
            throw DictionaryCheckFailure(description: "Sentence source disappeared after scrolling")
        }

        let loadingState = DictionaryPanelViewState(
            query: sentence,
            sourceLanguage: .spanish,
            mode: .sentence,
            isLoading: true,
            word: nil,
            sentence: sentenceState.sentence
        )
        panel.update(state: loadingState)
        guard let loadingGeometry = sentenceGeometry(content, source: sentence) else {
            throw DictionaryCheckFailure(description: "Sentence source disappeared during lookup")
        }
        try check(sameSentenceGeometry(scrolledTallGeometry, loadingGeometry),
                  "Looking up status moved the sentence source while scrolled")

        let errorState = DictionaryPanelViewState(
            query: sentence,
            sourceLanguage: .spanish,
            mode: .sentence,
            errorMessage: "Dictionary service is unavailable.",
            word: nil,
            sentence: sentenceState.sentence
        )
        panel.update(state: errorState)
        guard let errorGeometry = sentenceGeometry(content, source: sentence) else {
            throw DictionaryCheckFailure(description: "Sentence source disappeared in error state")
        }
        try check(sameSentenceGeometry(scrolledTallGeometry, errorGeometry),
                  "Lookup error moved the sentence source while scrolled")

        panel.update(state: sentenceState)
        guard let shortGeometry = sentenceGeometry(content, source: sentence) else {
            throw DictionaryCheckFailure(description: "Sentence source disappeared for the short entry")
        }
        try check(sameSentenceGeometry(scrolledTallGeometry, shortGeometry),
                  "A different word entry height moved the sentence source")
        panel.update(state: tallState)
        guard let finalGeometry = sentenceGeometry(content, source: sentence) else {
            throw DictionaryCheckFailure(description: "Sentence source disappeared after restoring the entry")
        }
        try check(sameSentenceGeometry(scrolledTallGeometry, finalGeometry),
                  "Restoring a tall entry moved the scrolled sentence source")
        try check(tallGeometry.documentOrigin.y == finalGeometry.documentOrigin.y,
                  "Sentence source document origin changed during state transitions")
        window.makeFirstResponder(nil)
        let next = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
                                   charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)!
        try check(window.performKeyEquivalent(with: next) && selectedWords.last == "idiomas", "Keyboard sentence navigation failed")
        window.cancelOperation(nil)
        try check(!panel.isVisible && dismissCount == 1, "Dismissal did not cancel the dictionary session once")
        print("PASS native panel focus, exact sentence display, layout, and dismissal")
    }

    @MainActor
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    struct SentenceGeometry {
        let documentOrigin: NSPoint
        let contentOrigin: NSPoint
        let windowTop: CGFloat
    }

    @MainActor
    static func sentenceGeometry(_ content: NSView, source: String) -> SentenceGeometry? {
        guard let sourceView = descendants(content)
            .compactMap({ $0 as? NSTextView })
            .first(where: {
                $0.accessibilityLabel() == "Sentence source" && $0.string == source
            }),
            let scrollView = sourceView.enclosingScrollView,
            let document = scrollView.documentView,
            let window = content.window
        else { return nil }
        return SentenceGeometry(
            documentOrigin: sourceView.convert(.zero, to: document),
            contentOrigin: sourceView.convert(.zero, to: content),
            windowTop: window.frame.maxY
        )
    }

    @MainActor
    static func sameSentenceGeometry(
        _ left: SentenceGeometry,
        _ right: SentenceGeometry,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        abs(left.documentOrigin.x - right.documentOrigin.x) <= tolerance
            && abs(left.documentOrigin.y - right.documentOrigin.y) <= tolerance
            && abs(left.contentOrigin.x - right.contentOrigin.x) <= tolerance
            && abs(left.contentOrigin.y - right.contentOrigin.y) <= tolerance
            && abs(left.windowTop - right.windowTop) <= tolerance
    }

    @MainActor
    static func savePreview(_ window: NSWindow, name: String) throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--previews"),
              CommandLine.arguments.indices.contains(index + 1), let view = window.contentView else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw DictionaryCheckFailure(description: "Cannot render panel preview")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw DictionaryCheckFailure(description: "Cannot encode panel preview")
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    static func liveDictionary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DictionaryLookupService(cacheDirectoryURL: directory)
        for (language, word) in [
            ("en", "hello"),
            ("es", "casa"),
            ("zh", "你好"),
            ("zh", "参考"),
            ("zh", "画蛇添足"),
            ("zh", "一举两得"),
            ("zh", "資產"),
            ("zh", "參考"),
            ("zh", "畫蛇添足"),
            ("zh", "一舉兩得"),
            ("ja", "食べる")
        ] {
            let result = try await service.lookup(language: language, word: word)
            try check(result.word == word, "Live lookup changed submitted word for \(language): \(word)")
            try check(result.entries.contains { $0.language.rawValue == language && !$0.senses.isEmpty },
                      "Live lookup missing \(language) entry for \(word)")
            try check(result.entries.first?.attribution?.sourceURL != nil, "Live source attribution was lost")
            print("PASS live dictionary \(language): \(word)")
        }
    }
}
