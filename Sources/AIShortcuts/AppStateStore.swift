import AIShortcutsCore
import Foundation

@MainActor
final class AppStateStore {
    private enum Key {
        static let welcomeDismissed = "welcomeDismissed.v1"
        static let permissionsRequested = "permissionsRequested.v1"
        static let safetyIdentifier = "safetyIdentifier.v1"
        static let disabledShortcutActions = "disabledShortcutActions.v1"
        static let aiProvider = "aiProvider.v1"
        static let openAIEndpoint = "openAIEndpoint.v1"
        static let openAIModel = "openAIModel.v1"
        static let anthropicEndpoint = "anthropicEndpoint.v1"
        static let anthropicModel = "anthropicModel.v1"
        static let dictionaryTargetLanguage = "dictionaryTargetLanguage.v1"
        static let dictionaryPresentationMode = "dictionaryPresentationMode.v1"
    }

    private static let defaultDictionaryTargetLanguage = "en"
    private static let dictionaryTargetLanguages: Set<String> = ["en", "es", "zh", "zh-hant", "ja"]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var welcomeDismissed: Bool {
        get { defaults.bool(forKey: Key.welcomeDismissed) }
        set { defaults.set(newValue, forKey: Key.welcomeDismissed) }
    }

    /// The language used for dictionary definitions and optional sentence
    /// translation. Store the panel's stable raw value rather than a display
    /// name so the preference remains portable across localized interfaces.
    var dictionaryTargetLanguage: String {
        get {
            let stored = defaults.string(forKey: Key.dictionaryTargetLanguage)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let stored,
                  Self.dictionaryTargetLanguages.contains(stored)
            else {
                return Self.defaultDictionaryTargetLanguage
            }
            return stored
        }
        set {
            let normalized = newValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            defaults.set(
                Self.dictionaryTargetLanguages.contains(normalized)
                    ? normalized
                    : Self.defaultDictionaryTargetLanguage,
                forKey: Key.dictionaryTargetLanguage
            )
        }
    }

    var dictionaryPresentationMode: DictionaryPresentationMode {
        get {
            DictionaryPresentationMode(rawValue: defaults.string(forKey: Key.dictionaryPresentationMode) ?? "")
                ?? .dictionary
        }
        set { defaults.set(newValue.rawValue, forKey: Key.dictionaryPresentationMode) }
    }

    var permissionsRequested: Bool {
        get { defaults.bool(forKey: Key.permissionsRequested) }
        set { defaults.set(newValue, forKey: Key.permissionsRequested) }
    }

    var aiProvider: AIProvider {
        get {
            AIProvider(rawValue: defaults.string(forKey: Key.aiProvider) ?? "")
                ?? .openAICompatible
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.aiProvider)
        }
    }

    func aiProviderConfiguration(for provider: AIProvider) -> AIProviderConfiguration {
        let fallback = AIProviderConfiguration.defaultConfiguration(for: provider)
        let endpointString = defaults.string(forKey: endpointKey(for: provider)) ?? ""
        let model = defaults.string(forKey: modelKey(for: provider)) ?? ""
        let configuration = AIProviderConfiguration(
            provider: provider,
            endpoint: URL(string: endpointString) ?? fallback.endpoint,
            model: model.isEmpty ? fallback.model : model
        )
        return configuration.validationMessage == nil ? configuration : fallback
    }

    func saveAIProviderConfiguration(_ configuration: AIProviderConfiguration) {
        defaults.set(configuration.provider.rawValue, forKey: Key.aiProvider)
        defaults.set(
            configuration.endpoint.absoluteString,
            forKey: endpointKey(for: configuration.provider)
        )
        defaults.set(
            configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: modelKey(for: configuration.provider)
        )
    }

    var safetyIdentifier: String {
        if let existing = defaults.string(forKey: Key.safetyIdentifier), !existing.isEmpty {
            return existing
        }
        let identifier = "ai-shortcuts-\(UUID().uuidString.lowercased())"
        defaults.set(identifier, forKey: Key.safetyIdentifier)
        return identifier
    }

    var enabledShortcutActions: Set<AIShortcutAction> {
        let disabledRawValues = disabledShortcutRawValues
        return Set(AIShortcutAction.allCases.filter {
            !disabledRawValues.contains($0.rawValue)
        })
    }

    func setShortcut(_ action: AIShortcutAction, enabled: Bool) {
        var disabled = disabledShortcutRawValues
        if enabled {
            disabled.remove(action.rawValue)
        } else {
            disabled.insert(action.rawValue)
        }
        defaults.set(disabled.sorted(), forKey: Key.disabledShortcutActions)
    }

    private var disabledShortcutRawValues: Set<UInt32> {
        Set((defaults.array(forKey: Key.disabledShortcutActions) ?? []).compactMap {
            ($0 as? NSNumber)?.uint32Value
        })
    }

    private func endpointKey(for provider: AIProvider) -> String {
        switch provider {
        case .openAICompatible:
            Key.openAIEndpoint
        case .anthropic:
            Key.anthropicEndpoint
        }
    }

    private func modelKey(for provider: AIProvider) -> String {
        switch provider {
        case .openAICompatible:
            Key.openAIModel
        case .anthropic:
            Key.anthropicModel
        }
    }
}
