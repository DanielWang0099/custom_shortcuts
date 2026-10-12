import AIShortcutsCore
import Foundation

private struct TranslationLanguageCheckFailure: Error, CustomStringConvertible {
    let description: String
}

func dictionaryTranslationLanguageChecks() async throws {
    let cases: [(String, String?, String, String)] = [
        ("auto", "en", "en", "zh"),
        ("auto", "en-US", "English", "zh"),
        ("auto", "es", "es", "en"),
        ("auto", "ja", "ja", "en"),
        ("auto", "zh", "zh", "en"),
        ("auto", "zh-Hant", "zh-hant", "en"),
        ("auto", "zh-Hans", "zh-hant", "zh-hant"),
        ("auto", "zh-Hant", "ch", "zh"),
        ("en", "ja", "en", "zh"),
        ("es", "en", "en", "en"),
        ("en", nil, "es", "es"),
        ("auto", "ja", "zh", "zh"),
        ("auto", "fr", "en", "en"),
        ("auto", nil, "en", "en"),
        ("auto", "und", "ja", "ja"),
    ]
    for (source, detected, preferred, expected) in cases {
        let actual = DictionaryTranslationLanguagePolicy.targetLanguage(
            sourceLanguage: source,
            detectedSourceLanguage: detected,
            preferredTargetLanguage: preferred
        )
        guard actual == expected else {
            throw TranslationLanguageCheckFailure(description:
                "Translation language \(source)/\(detected ?? "unknown") → \(preferred) resolved to \(actual), expected \(expected)")
        }
    }
    let equivalent: [(String, String)] = [
        ("en-GB", "en-US"), ("es-MX", "es"), ("ja_JP", "ja"),
        ("zh-CN", "zh-Hans"), ("zh-TW", "zh-Hant"), ("cmn", "zh"),
        ("  EN  ", "english"),
    ]
    for (source, target) in equivalent {
        guard DictionaryTranslationLanguagePolicy.isSameLanguage(source, target) else {
            throw TranslationLanguageCheckFailure(description: "Equivalent language tags were allowed: \(source) → \(target)")
        }
    }
    for (source, target) in [("zh", "zh-Hant"), ("zh-Hant", "zh-Hans"), ("en", "es"), ("auto", "auto"), ("und", "en")] {
        guard !DictionaryTranslationLanguagePolicy.isSameLanguage(source, target) else {
            throw TranslationLanguageCheckFailure(description: "Useful or unknown language pair was blocked: \(source) → \(target)")
        }
    }
}
