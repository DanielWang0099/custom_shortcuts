import AIShortcutsCore
import Foundation
import LocalAuthentication
import Security

private struct LiveAICheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func validateMixedSentenceResponse(
    _ response: DictionaryAIResponse,
    source: String
) throws {
    let sourceNSString = source as NSString
    let sourceLength = sourceNSString.length
    let normalizedTranslation = response.translation?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let normalizedTranslation, !normalizedTranslation.isEmpty else {
        throw LiveAICheckFailure(description: "Live mixed sentence translation was empty")
    }
    let normalizedSource = source
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    guard normalizedTranslation != normalizedSource,
          !normalizedTranslation.contains("…"),
          !normalizedTranslation.contains("...")
    else {
        throw LiveAICheckFailure(description: "Live mixed sentence translation was not a complete translated result")
    }

    for token in response.segmentedTokens {
        let range = token.sourceRange
        guard range.location >= 0,
              range.length > 0,
              range.location <= sourceLength,
              range.length <= sourceLength - range.location,
              sourceNSString.substring(with: range) == token.text
        else {
            throw LiveAICheckFailure(description: "Live mixed sentence returned a token range that does not match its source")
        }
    }

    func sourceRange(of text: String, afterUTF16 start: Int = 0) -> NSRange? {
        guard start >= 0, start <= sourceLength else { return nil }
        let range = sourceNSString.range(
            of: text,
            options: [],
            range: NSRange(location: start, length: sourceLength - start)
        )
        return range.location == NSNotFound ? nil : range
    }

    guard let referenceRange = sourceRange(of: "参考"),
          let firstIdiomRange = sourceRange(of: "画蛇添足"),
          let secondIdiomRange = sourceRange(
              of: "画蛇添足",
              afterUTF16: NSMaxRange(firstIdiomRange)
          )
    else {
        throw LiveAICheckFailure(description: "Mixed sentence fixture ranges are incomplete")
    }

    let references = response.segmentedTokens.filter { $0.text == "参考" }
    guard references.count == 1,
          references[0].sourceRange == referenceRange
    else {
        throw LiveAICheckFailure(description: "Live mixed sentence did not preserve one exact 参考 token")
    }

    let idioms = response.segmentedTokens.filter { $0.text == "画蛇添足" }
    guard idioms.count == 2,
          idioms.contains(where: { $0.sourceRange == firstIdiomRange }),
          idioms.contains(where: { $0.sourceRange == secondIdiomRange }),
          idioms[0].sourceRange != idioms[1].sourceRange
    else {
        throw LiveAICheckFailure(description: "Live mixed sentence did not preserve both exact 画蛇添足 token ranges")
    }

    // Native word ranges may be split by NaturalLanguage before dictionary
    // compounds are recovered. A response token covering a native range is
    // sufficient; exact compound assertions above catch accidental character
    // fragmentation for the user-visible terms.
    let nativeWords = DictionaryLanguageService.tokenize(source)
        .filter(\.isWord)
    guard nativeWords.allSatisfy({ native in
        response.segmentedTokens.contains { token in
            token.sourceRange.location <= native.utf16Range.location
                && NSMaxRange(token.sourceRange) >= NSMaxRange(native.utf16Range)
        }
    }) else {
        throw LiveAICheckFailure(description: "Live mixed sentence segmentation omitted native word content")
    }
}

/// Explicit opt-in integration check. Uses the app's configured provider and
/// existing Keychain credential without displaying credentials or prompting.
@MainActor
func dictionaryLiveAIChecks() async throws {
    guard let defaults = UserDefaults(suiteName: AppConfiguration.bundleIdentifier) else {
        throw LiveAICheckFailure(description: "Cannot read configured app preferences")
    }
    let state = AppStateStore(defaults: defaults)
    let configuration = state.aiProviderConfiguration(for: state.aiProvider)
    // The login Keychain's legacy ACL path can ignore LAContext and block on
    // a code-signature approval dialog after the harness has been rebuilt.
    // Fail instead of opening UI; this switch affects only this test process.
    guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
        throw LiveAICheckFailure(description: "Cannot disable Keychain prompts for the opt-in check")
    }
    let context = LAContext()
    context.interactionNotAllowed = true
    let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: AppConfiguration.keychainService(for: state.aiProvider),
        kSecAttrAccount as String: AppConfiguration.keychainAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationContext as String: context,
    ]
    var stored: CFTypeRef?
    let status = SecItemCopyMatching(identity as CFDictionary, &stored)
    guard status == errSecSuccess, let data = stored as? Data,
          let apiKey = String(data: data, encoding: .utf8), !apiKey.isEmpty else {
        throw LiveAICheckFailure(description: "Configured AI key is unavailable to the opt-in check (Keychain status \(status))")
    }
    let client = AIProviderClient()
    let mixedSentence = "Please 参考这份资料。不要画蛇添足，画蛇添足反而不好。"
    let requests: [DictionaryAIRequest] = [
        .sentenceContext(sourceText: "Me gusta aprender idiomas.", sourceLanguage: .es,
                         targetLanguage: .en, includeSegmentation: false, includeReadings: false),
        .sentenceContext(sourceText: mixedSentence, sourceLanguage: .en,
                         targetLanguage: .en, includeSegmentation: true, includeReadings: false),
        .entryEnrichment(entry: .init(headword: "食べる", language: .ja,
                                     senses: [.init(definition: "to eat", examples: ["ご飯を食べる。", "毎朝パンを食べます。"])]),
                         sentence: "食べる", sourceLanguage: .ja, targetLanguage: .en),
        .entryEnrichment(entry: .init(headword: "你好", language: .zh,
                                     senses: [.init(definition: "hello", examples: ["你好，很高兴认识你。", "老师，你好！"])]),
                         sentence: "你好", sourceLanguage: .zh, targetLanguage: .en),
    ]
    for request in requests {
        let response: DictionaryAIResponse
        do {
            response = try await client.completeDictionary(request: request, apiKey: apiKey,
                                                          safetyIdentifier: "dictionary-integration-check",
                                                          configuration: configuration)
        } catch {
            // Provider errors can contain request diagnostics. Avoid echoing
            // those in logs from a check that has access to a real credential.
            let failure: String
            switch error {
            case let ResponsesAPIError.httpStatus(status, _): failure = "HTTP \(status)"
            case let ResponsesAPIError.invalidOutput(message):
                switch message {
                case "The AI provider returned an invalid token range.": failure = "invalid token range"
                case "The AI provider returned token text that does not match its UTF-16 range.": failure = "UTF-16 token mismatch"
                case "The AI provider returned an invalid dictionary answer.": failure = "invalid dictionary JSON"
                default: failure = "dictionary response validation"
                }
            case ResponsesAPIError.incomplete: failure = "incomplete response"
            case ResponsesAPIError.malformedResponse: failure = "malformed response"
            case let error as URLError: failure = "network code \(error.code.rawValue)"
            default: failure = "provider response"
            }
            throw LiveAICheckFailure(description: "Configured AI dictionary request failed for \(request.kind.rawValue): \(failure)")
        }
        switch request {
        case let .sentenceContext(sentenceRequest):
            guard response.translation?.isEmpty == false else {
                throw LiveAICheckFailure(description: "Live sentence translation was empty")
            }
            if sentenceRequest.sourceText == mixedSentence {
                try validateMixedSentenceResponse(response, source: mixedSentence)
                print("PASS live configured AI mixed Chinese idiom sentence segmentation")
            }
            print("PASS live configured AI sentence translation")
        case let .entryEnrichment(entry):
            guard !response.readings.isEmpty, !response.targetDefinitions.isEmpty,
                  response.exampleTranslations.count == 2 else {
                throw LiveAICheckFailure(description: "Live AI entry lacked readings, definitions, or two translated examples")
            }
            print("PASS live configured AI \(entry.entry.language.rawValue) readings and example translations")
        }
    }
}
