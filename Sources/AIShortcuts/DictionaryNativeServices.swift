import AVFoundation
import AIShortcutsCore
import AppKit
import CoreServices
import Foundation
import NaturalLanguage
import Vision

// MARK: - Language and token services

/// A token produced by the native tokenizer. Ranges are UTF-16 ranges so they
/// can be used directly with AppKit text controls and the ranges returned by
/// Vision. Whitespace is represented too, which lets callers rebuild the
/// source text without losing punctuation, spacing, or line breaks.
public struct DictionaryNativeToken: Equatable, Sendable {
    public let text: String
    public let utf16Range: NSRange
    public let lemma: String?
    /// The language used for this token's local lookup. Automatic mixed
    /// language tokenization fills this from the token's script; an explicit
    /// source override fills it with the override for every word token.
    public let language: DictionarySourceLanguage?
    public let isPunctuation: Bool
    public let isWhitespace: Bool

    public var isWord: Bool {
        !isWhitespace && !isPunctuation
    }

    public init(
        text: String,
        utf16Range: NSRange,
        lemma: String? = nil,
        isPunctuation: Bool,
        isWhitespace: Bool,
        language: DictionarySourceLanguage? = nil
    ) {
        self.text = text
        self.utf16Range = utf16Range
        self.lemma = lemma
        self.language = language
        self.isPunctuation = isPunctuation
        self.isWhitespace = isWhitespace
    }
}

/// Native language recognition and tokenization used by Dictionary. Chinese
/// starts with Apple's language-aware tokenizer, then uses exact terms from
/// the installed macOS Dictionary only when a term spans tokenizer boundaries.
/// This keeps ordinary sentence segmentation intact while recovering compounds
/// and idioms such as four-character entries without grouping arbitrary runs.
public enum DictionaryLanguageService {
    private enum ScriptClass: Equatable {
        case han
        case kana
        case latin
        case separator
    }

    private struct ScriptRun {
        let range: Range<String.Index>
        let script: ScriptClass
        let joinsJapaneseScripts: Bool
    }

    /// DCS calls are synchronous. A small shared cache and a per-tokenization
    /// budget keep a long OCR result from making the first shortcut stall.
    private static let chineseDictionaryCache = ChineseDictionaryProbeCache()
    private static let maximumChineseDictionaryProbes = 128

    private final class ChineseDictionaryProbeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var positive: Set<String> = []
        private var negative: Set<String> = []
        private let maximumEntries = 512

        func exactDefinitionExists(for term: String) -> Bool {
            lock.lock()
            if positive.contains(term) {
                lock.unlock()
                return true
            }
            if negative.contains(term) {
                lock.unlock()
                return false
            }
            lock.unlock()

            let cfTerm = term as CFString
            let fullRange = CFRange(location: 0, length: CFStringGetLength(cfTerm))
            let exactRange = DCSGetTermRangeInString(nil, cfTerm, 0)
            let definition = DCSCopyTextDefinition(nil, cfTerm, fullRange)
                .map { $0.takeRetainedValue() as String }
            let isExact = exactRange.location == 0
                && exactRange.length == fullRange.length
                && !(definition?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

            lock.lock()
            if isExact {
                positive.insert(term)
            } else {
                negative.insert(term)
            }
            while positive.count + negative.count > maximumEntries {
                if let value = positive.first {
                    positive.remove(value)
                } else if let value = negative.first {
                    negative.remove(value)
                }
            }
            lock.unlock()
            return isExact
        }
    }

    /// Returns whether a token contains at least one letter or number. Native
    /// tokenizer gaps can contain punctuation mixed with spaces/newlines (for
    /// example ".\n" or ", "); those ranges must not become navigable words.
    public static func isWordContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    public static func detect(
        _ text: String,
        preferred: DictionarySourceLanguage = .automatic
    ) -> DictionarySourceLanguage {
        if preferred != .automatic {
            return preferred
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .english
        }

        // Kana is a reliable signal for Japanese even when the input is a
        // short word that NaturalLanguage cannot classify with confidence.
        if trimmed.unicodeScalars.contains(where: Self.isJapaneseKana) {
            return .japanese
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        if let language = recognizer.dominantLanguage {
            switch language {
            case .japanese:
                return .japanese
            case .simplifiedChinese, .traditionalChinese:
                return ChineseScript.detect(trimmed) == .traditional ? .traditionalChinese : .chinese
            case .spanish:
                return .spanish
            case .english:
                return .english
            default:
                return DictionarySourceLanguage(rawValue: language.rawValue)
            }
        }

        // Han-only text is much more likely to be Chinese than English,
        // and the source-language popup remains available for correction.
        if trimmed.unicodeScalars.contains(where: Self.isHan) {
            return ChineseScript.detect(trimmed) == .traditional ? .traditionalChinese : .chinese
        }
        return .english
    }

    public static func hypotheses(
        for text: String,
        maximum: Int = 4
    ) -> [(language: DictionarySourceLanguage, confidence: Double)] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: maximum)
        return hypotheses.compactMap { language, confidence in
            guard let mapped = map(language) else { return nil }
            return (mapped, confidence)
        }
    }

    public static func tokenize(
        _ text: String,
        language: DictionarySourceLanguage = .automatic,
        dictionaryProbeLimit: Int = 8
    ) -> [DictionaryNativeToken] {
        guard !text.isEmpty else { return [] }

        let resolvedLanguage = language.isAutomatic ? detect(text) : language
        let runs = scriptRuns(
            in: text,
            joinJapaneseScripts: resolvedLanguage.canonicalCode == "ja"
        )
        var tokens: [DictionaryNativeToken] = []
        for run in runs {
            let runText = String(text[run.range])
            guard run.script != .separator else {
                tokens.append(
                    Self.makeToken(
                        runText,
                        utf16Range: NSRange(run.range, in: text),
                        language: nil
                    )
                )
                continue
            }

            let tokenLanguage = Self.tokenLanguage(
                for: runText,
                script: run.script,
                joinsJapaneseScripts: run.joinsJapaneseScripts,
                explicitLanguage: language.isAutomatic ? nil : language,
                detectedLanguage: resolvedLanguage
            )
            tokens.append(contentsOf: Self.tokenizeWordRun(
                runText,
                source: text,
                sourceRange: run.range,
                language: tokenLanguage
            ))
        }

        return refineChineseCompounds(
            in: tokens,
            dictionaryProbeLimit: dictionaryProbeLimit
        )
    }

    /// Refines an existing native token list with exact macOS Dictionary
    /// terms. Callers can use the small default probe budget during initial
    /// panel presentation, then run this larger bounded pass off the main
    /// actor when a sentence needs fuller Chinese compound coverage.
    public static func refineChineseCompounds(
        in tokens: [DictionaryNativeToken],
        dictionaryProbeLimit: Int = 128
    ) -> [DictionaryNativeToken] {
        mergeChineseDictionaryTerms(
            in: tokens,
            probeLimit: dictionaryProbeLimit
        )
    }

    public static func lemma(
        for token: String,
        language: DictionarySourceLanguage = .automatic
    ) -> String? {
        guard !token.isEmpty,
              !token.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) })
        else {
            return nil
        }

        // NaturalLanguage provides useful inflection hints for Latin scripts
        // and some CJK inputs. It never performs transliteration, which is
        // important for Japanese readings.
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = token
        let resolvedLanguage = language.isAutomatic ? detect(token) : language
        if !resolvedLanguage.isAutomatic {
            tagger.setLanguage(
                Self.nlLanguage(for: resolvedLanguage),
                range: token.startIndex..<token.endIndex
            )
        }
        let result = tagger.tag(
            at: token.startIndex,
            unit: .word,
            scheme: .lemma
        )
        if let value = result.0, !value.rawValue.isEmpty {
            return value.rawValue
        }
        return token
    }

    private static func makeToken(
        _ value: String,
        utf16Range: NSRange,
        language: DictionarySourceLanguage?
    ) -> DictionaryNativeToken {
        let whitespace = value.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let punctuation = !whitespace && !isWordContent(value)
        return DictionaryNativeToken(
            text: value,
            utf16Range: utf16Range,
            lemma: punctuation || whitespace || language == nil
                ? nil
                : lemma(for: value, language: language!),
            isPunctuation: punctuation,
            isWhitespace: whitespace,
            language: punctuation || whitespace ? nil : language
        )
    }

    private static func scriptRuns(
        in text: String,
        joinJapaneseScripts: Bool
    ) -> [ScriptRun] {
        guard !text.isEmpty else { return [] }
        var runs: [ScriptRun] = []
        var start = text.startIndex
        var index = text.index(after: start)
        var current = scriptClass(for: text[start])
        var currentJoinsJapaneseScripts = false

        while index < text.endIndex {
            let next = scriptClass(for: text[index])
            let joinsJapaneseScripts = joinJapaneseScripts
                && next != current
                && isJapaneseScript(current)
                && isJapaneseScript(next)
            let bridgesLatinRun = current == .latin
                && next == .separator
                && separatorIsFollowedByLatin(in: text, from: index)
            if next != current && !joinsJapaneseScripts && !bridgesLatinRun {
                runs.append(ScriptRun(
                    range: start..<index,
                    script: current,
                    joinsJapaneseScripts: currentJoinsJapaneseScripts
                ))
                start = index
                current = next
                currentJoinsJapaneseScripts = false
            } else if joinsJapaneseScripts {
                currentJoinsJapaneseScripts = true
            }
            index = text.index(after: index)
        }
        runs.append(ScriptRun(
            range: start..<text.endIndex,
            script: current,
            joinsJapaneseScripts: currentJoinsJapaneseScripts
        ))
        return runs
    }

    private static func tokenizeWordRun(
        _ runText: String,
        source: String,
        sourceRange: Range<String.Index>,
        language: DictionarySourceLanguage
    ) -> [DictionaryNativeToken] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = runText
        tokenizer.setLanguage(Self.nlLanguage(for: language))

        let sourceBase = NSRange(sourceRange, in: source).location
        var tokens: [DictionaryNativeToken] = []
        var cursor = runText.startIndex
        tokenizer.enumerateTokens(in: runText.startIndex..<runText.endIndex) { tokenRange, _ in
            if cursor < tokenRange.lowerBound {
                let gap = String(runText[cursor..<tokenRange.lowerBound])
                tokens.append(
                    Self.makeToken(
                        gap,
                        utf16Range: Self.globalRange(
                            for: NSRange(cursor..<tokenRange.lowerBound, in: runText),
                            sourceBase: sourceBase
                        ),
                        language: nil
                    )
                )
            }

            let word = String(runText[tokenRange])
            tokens.append(
                Self.makeToken(
                    word,
                    utf16Range: Self.globalRange(
                        for: NSRange(tokenRange, in: runText),
                        sourceBase: sourceBase
                    ),
                    language: language
                )
            )
            cursor = tokenRange.upperBound
            return true
        }

        if cursor < runText.endIndex {
            let tail = String(runText[cursor..<runText.endIndex])
            tokens.append(
                Self.makeToken(
                    tail,
                    utf16Range: Self.globalRange(
                        for: NSRange(cursor..<runText.endIndex, in: runText),
                        sourceBase: sourceBase
                    ),
                    language: nil
                )
            )
        }

        if tokens.isEmpty {
            tokens.append(
                Self.makeToken(
                    runText,
                    utf16Range: NSRange(sourceRange, in: source),
                    language: language
                )
            )
        }
        return tokens
    }

    private static func globalRange(for local: NSRange, sourceBase: Int) -> NSRange {
        NSRange(location: sourceBase + local.location, length: local.length)
    }

    private static func tokenLanguage(
        for text: String,
        script: ScriptClass,
        joinsJapaneseScripts: Bool,
        explicitLanguage: DictionarySourceLanguage?,
        detectedLanguage: DictionarySourceLanguage
    ) -> DictionarySourceLanguage {
        if let explicitLanguage {
            return explicitLanguage
        }
        switch script {
        case .han:
            return joinsJapaneseScripts || detectedLanguage.canonicalCode == "ja"
                ? .japanese
                : (ChineseScript.detect(text) == .traditional ? .traditionalChinese : .chinese)
        case .kana:
            return .japanese
        case .latin:
            if ["en", "es", "fr"].contains(detectedLanguage.canonicalCode) {
                return detectedLanguage
            }
            return detect(text)
        case .separator:
            return detectedLanguage
        }
    }

    private static func scriptClass(for character: Character) -> ScriptClass {
        if character.unicodeScalars.contains(where: Self.isHan) {
            return .han
        }
        if character.unicodeScalars.contains(where: Self.isJapaneseKana) {
            return .kana
        }
        if character.unicodeScalars.contains(where: {
            CharacterSet.alphanumerics.contains($0)
        }) {
            return .latin
        }
        return .separator
    }

    private static func isJapaneseScript(_ script: ScriptClass) -> Bool {
        script == .han || script == .kana
    }

    private static func separatorIsFollowedByLatin(
        in text: String,
        from index: String.Index
    ) -> Bool {
        var probe = index
        while probe < text.endIndex, scriptClass(for: text[probe]) == .separator {
            probe = text.index(after: probe)
        }
        return probe < text.endIndex && scriptClass(for: text[probe]) == .latin
    }

    private static func mergeChineseDictionaryTerms(
        in tokens: [DictionaryNativeToken],
        probeLimit requestedProbeLimit: Int
    ) -> [DictionaryNativeToken] {
        guard tokens.count > 1 else { return tokens }
        var result: [DictionaryNativeToken] = []
        var index = 0
        var probes = 0
        let probeLimit = min(
            max(requestedProbeLimit, 0),
            maximumChineseDictionaryProbes
        )

        while index < tokens.count {
            guard isChineseHanToken(tokens[index]) else {
                result.append(tokens[index])
                index += 1
                continue
            }

            let blockStart = index
            while index < tokens.count, isChineseHanToken(tokens[index]) {
                index += 1
            }
            let block = Array(tokens[blockStart..<index])
            guard block.count > 1 else {
                result.append(contentsOf: block)
                continue
            }

            let blockText = block.map(\.text).joined()
            let blockBase = block[0].utf16Range.location
            let blockLength = (blockText as NSString).length
            var tokenStarts = Set<Int>()
            var tokenEnds = Set<Int>()
            for token in block {
                let start = token.utf16Range.location - blockBase
                tokenStarts.insert(start)
                tokenEnds.insert(start + token.utf16Range.length)
            }

            var localIndex = 0
            while localIndex < block.count {
                if Task.isCancelled {
                    result.append(contentsOf: block[localIndex...])
                    break
                }
                guard probes < probeLimit else {
                    result.append(contentsOf: block[localIndex...])
                    break
                }

                let token = block[localIndex]
                let localOffset = token.utf16Range.location - blockBase
                let termRange = DCSGetTermRangeInString(
                    nil,
                    blockText as CFString,
                    CFIndex(localOffset)
                )
                probes += 1
                if Task.isCancelled {
                    result.append(contentsOf: block[localIndex...])
                    break
                }

                let candidateLength = termRange.length
                let candidateEnd = termRange.location + candidateLength
                guard termRange.location == localOffset,
                      candidateLength >= 2,
                      candidateLength <= 8,
                      candidateEnd <= blockLength,
                      tokenStarts.contains(localOffset),
                      tokenEnds.contains(candidateEnd)
                else {
                    result.append(token)
                    localIndex += 1
                    continue
                }

                let candidate = (blockText as NSString).substring(
                    with: NSRange(location: localOffset, length: candidateLength)
                )
                guard candidate.count >= 2,
                      candidate.count <= 8,
                      candidate.unicodeScalars.allSatisfy(Self.isHan),
                      chineseDictionaryCache.exactDefinitionExists(for: candidate),
                      let endIndex = block.firstIndex(where: {
                          $0.utf16Range.location - blockBase + $0.utf16Range.length == candidateEnd
                      })
                else {
                    result.append(token)
                    localIndex += 1
                    continue
                }

                let merged = DictionaryNativeToken(
                    text: candidate,
                    utf16Range: NSRange(
                        location: blockBase + localOffset,
                        length: candidateLength
                    ),
                    lemma: candidate,
                    isPunctuation: false,
                    isWhitespace: false,
                    language: token.language
                )
                result.append(merged)
                localIndex = block.distance(from: block.startIndex, to: endIndex) + 1
            }
        }
        return result
    }

    private static func isChineseHanToken(_ token: DictionaryNativeToken) -> Bool {
        guard token.isWord,
              token.language?.canonicalCode == "zh"
        else { return false }
        return token.text.unicodeScalars.allSatisfy(Self.isHan)
    }

    private static func map(_ language: NLLanguage) -> DictionarySourceLanguage? {
        switch language {
        case .english: return .english
        case .spanish: return .spanish
        case .simplifiedChinese: return .chinese
        case .traditionalChinese: return .traditionalChinese
        case .japanese: return .japanese
        default:
            let raw = language.rawValue
            guard !raw.isEmpty else { return nil }
            return DictionarySourceLanguage(rawValue: raw)
        }
    }

    private static func nlLanguage(for language: DictionarySourceLanguage) -> NLLanguage {
        if language.rawValue.lowercased() == "zh-hant" { return .traditionalChinese }
        return switch language.canonicalCode {
        case "en": .english
        case "es": .spanish
        case "zh": .simplifiedChinese
        case "ja": .japanese
        default: NLLanguage(rawValue: language.rawValue)
        }
    }

    private static func isJapaneseKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
    }
}

// MARK: - macOS Dictionary Services

public struct DictionaryNativeLookup: Equatable, Sendable {
    public let query: String
    public let definition: String
    public let sourceName: String
    public let sourceURL: URL?

    public init(
        query: String,
        definition: String,
        sourceName: String = "macOS Dictionary",
        sourceURL: URL? = nil
    ) {
        self.query = query
        self.definition = definition
        self.sourceName = sourceName
        self.sourceURL = sourceURL
    }
}

/// A fast local fallback. Dictionary Services may return an empty result when
/// the relevant dictionary is not installed, so callers should keep their
/// structured/network result and treat this as supplemental data.
public enum DictionaryNativeLookupService {
    public static func lookup(
        _ text: String,
        sourceLanguage: DictionarySourceLanguage = .automatic
    ) async throws -> DictionaryNativeLookup? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        try Task.checkCancellation()

        return await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil }
            return lookupSynchronously(query)
        }.value
    }

    public static func lookupSynchronously(
        _ text: String,
        sourceLanguage: DictionarySourceLanguage = .automatic
    ) -> DictionaryNativeLookup? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        let cfText = query as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfText))
        guard let unmanaged = DCSCopyTextDefinition(nil, cfText, range) else {
            return nil
        }
        let definition = unmanaged.takeRetainedValue() as String
        guard !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return DictionaryNativeLookup(
            query: query,
            definition: definition,
            sourceName: "macOS Dictionary"
        )
    }
}

// MARK: - Vision OCR

public enum DictionaryOCRService {
    public static func supportedRecognitionLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        if #available(macOS 12.0, *) {
            return (try? request.supportedRecognitionLanguages()) ?? []
        }
        return []
    }

    public static func recognizeText(from imageData: Data) async throws -> String {
        try Task.checkCancellation()

        let text = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.revision = VNRecognizeTextRequestRevision3
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    if #available(macOS 12.0, *) {
                        request.automaticallyDetectsLanguage = true
                        let supported = (try? request.supportedRecognitionLanguages()) ?? []
                        let preferred = ["en-US", "es-ES", "zh-Hans", "zh-Hant", "ja-JP"]
                        let selected = preferred.filter { language in
                            supported.contains(language)
                                || supported.contains(where: { $0.split(separator: "-").first == language.split(separator: "-").first })
                        }
                        if !selected.isEmpty {
                            request.recognitionLanguages = selected
                        }
                    }

                    let handler = VNImageRequestHandler(data: imageData, options: [:])
                    try handler.perform([request])

                    let observations = (request.results ?? []).sorted {
                        if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.02 {
                            return $0.boundingBox.midY > $1.boundingBox.midY
                        }
                        return $0.boundingBox.minX < $1.boundingBox.minX
                    }
                    let strings = observations.compactMap {
                        $0.topCandidates(1).first?.string.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                    }.filter { !$0.isEmpty }
                    continuation.resume(returning: strings.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
        return text
    }
}

// MARK: - Native speech

public enum DictionarySpeechKind: Equatable {
    case word
    case example
    case sentence
}

public struct DictionarySpeechRequest: Equatable {
    public let text: String
    public let language: DictionarySourceLanguage
    public let kind: DictionarySpeechKind
    public let rate: Float

    public init(
        text: String,
        language: DictionarySourceLanguage,
        kind: DictionarySpeechKind = .word,
        rate: Float = AVSpeechUtteranceDefaultSpeechRate
    ) {
        self.text = text
        self.language = language
        self.kind = kind
        self.rate = rate
    }
}

@MainActor
public final class DictionarySpeechService: NSObject, AVSpeechSynthesizerDelegate {
    public static let shared = DictionarySpeechService()

    private let synthesizer = AVSpeechSynthesizer()

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ request: DictionarySpeechRequest) {
        let value = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: value)
        utterance.voice = AVSpeechSynthesisVoice(language: request.language.speechLocale)
            ?? AVSpeechSynthesisVoice(language: DictionarySourceLanguage.english.speechLocale)
        utterance.rate = min(max(request.rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    public var isSpeaking: Bool {
        synthesizer.isSpeaking
    }
}

public extension DictionarySourceLanguage {
    var speechLocale: String {
        if rawValue.lowercased() == "zh-hant" { return "zh-TW" }
        return switch canonicalCode {
        case "auto", "en": "en-US"
        case "es": "es-ES"
        case "zh": "zh-CN"
        case "ja": "ja-JP"
        default: canonicalCode
        }
    }
}
