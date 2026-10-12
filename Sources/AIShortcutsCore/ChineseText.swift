import Foundation

/// Script policy shared by Translate and Dictionary. Dictionary transport still
/// uses the provider's base `zh` endpoint; these values describe presentation.
public enum ChineseScript: String, Sendable, Equatable {
    case simplified = "zh-Hans"
    case traditional = "zh-Hant"

    public init?(languageTag: String) {
        switch languageTag.lowercased() {
        case "zh", "zh-hans", "zh-cn": self = .simplified
        case "zh-hant", "zh-tw", "zh-hk": self = .traditional
        default: return nil
        }
    }

    public struct TargetInstruction: Equatable, Sendable {
        public let script: ChineseScript
        public let original: String

        public var prompt: String {
            let name = script == .simplified ? "Simplified Chinese (zh-Hans)" : "Traditional Chinese (zh-Hant)"
            return "\(original). Translate all Chinese prose into \(name); use that script consistently while preserving the requested tone and style. Preserve code and link destinations verbatim."
        }
    }

    public static func instruction(_ text: String) -> TargetInstruction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let startsChinese = lowered.range(
            of: #"^(?:ch|zh)(?:$|[-_,\s])|^chinese(?:$|[,_\s])|^中文(?:$|[,_\s])|^(?:simplified|traditional)\s+chinese(?:$|[,_\s])|^[简簡繁]體中文|^简体中文"#,
            options: .regularExpression
        ) != nil
        guard startsChinese else { return nil }
        let traditional = lowered.contains("traditional") || lowered.contains("hant")
            || lowered.hasPrefix("zh-tw") || lowered.hasPrefix("zh-hk")
            || lowered.contains("繁體") || lowered.contains("繁体")
        return TargetInstruction(script: traditional ? .traditional : .simplified, original: trimmed)
    }

    public static func detect(_ text: String) -> ChineseScript {
        // Shared Han glyphs have no script signal. Prefer the user's default.
        let simplified = ChineseScript.simplified.convert(text)
        return simplified == text ? .simplified : .traditional
    }

    public func convert(_ text: String) -> String {
        let transform = self == .simplified
            ? StringTransform("Traditional-Simplified")
            : StringTransform("Simplified-Traditional")
        return text.applyingTransform(transform, reverse: false) ?? text
    }

    /// Convert visible prose, leaving fenced/inline code and link destinations
    /// untouched. The regex finds protected spans first so the original bytes
    /// remain in the output even when the provider used the opposite script.
    public func convertProse(_ text: String) -> String {
        let pattern = #"(?m)^[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^[ \t]{0,3}\1[^\n]*|^[ \t]{0,3}\[[^\]\n]+\]:[ \t]*[^\n]+|(`+)(?:(?!\2)[^\n])*\2|\]\([^\n)]*\)|<https?://[^>]+>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return convert(text) }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: range) {
            guard let protected = Range(match.range, in: text), protected.lowerBound >= cursor else { continue }
            result += convert(String(text[cursor..<protected.lowerBound]))
            result += text[protected]
            cursor = protected.upperBound
        }
        result += convert(String(text[cursor...]))
        return result
    }
}
