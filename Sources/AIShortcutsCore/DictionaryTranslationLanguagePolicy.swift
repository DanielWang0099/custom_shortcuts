import Foundation

public enum DictionaryPresentationMode: String, Codable, Equatable, Sendable {
    case dictionary
    case translate
}

/// Keeps paragraph translation useful while preserving an explicitly chosen
/// target whenever it differs from the resolved source. Dictionary definitions
/// may legitimately use the source language and do not use this policy.
public enum DictionaryTranslationLanguagePolicy {
    public static func targetLanguage(
        sourceLanguage: String,
        detectedSourceLanguage: String? = nil,
        preferredTargetLanguage: String
    ) -> String {
        let source = normalizedLanguage(sourceLanguage)
            ?? detectedSourceLanguage.flatMap(normalizedLanguage)
        let target = normalizedLanguage(preferredTargetLanguage) ?? "en"
        guard let source, source == target else { return target }
        return source == "en" ? "zh" : "en"
    }

    public static func isSameLanguage(_ sourceLanguage: String, _ targetLanguage: String) -> Bool {
        guard let source = normalizedLanguage(sourceLanguage),
              let target = normalizedLanguage(targetLanguage)
        else { return false }
        return source == target
    }

    private static func normalizedLanguage(_ language: String) -> String? {
        let tag = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").lowercased()
        switch tag {
        case "", "auto", "und": return nil
        case "ch", "chinese", "中文", "简体中文", "simplified chinese": return "zh"
        case "繁體中文", "繁体中文", "traditional chinese": return "zh-hant"
        case "english": return "en"
        case "spanish", "español": return "es"
        case "japanese", "日本語": return "ja"
        default: break
        }
        let components = tag.split(separator: "-")
        guard let base = components.first else { return nil }
        if base == "zh" || base == "cmn" {
            return components.contains("hant") || components.contains("tw") || components.contains("hk")
                ? "zh-hant" : "zh"
        }
        return String(base)
    }
}
