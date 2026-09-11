import Foundation

public enum AIProvider: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case openAICompatible = "openai_compatible"
    case anthropic

    public var displayName: String {
        switch self {
        case .openAICompatible:
            "OpenAI-compatible"
        case .anthropic:
            "Anthropic"
        }
    }

    public var requestDescription: String {
        switch self {
        case .openAICompatible:
            "Chat Completions request"
        case .anthropic:
            "Messages request"
        }
    }

    public var defaultEndpoint: URL {
        switch self {
        case .openAICompatible:
            AppConstants.openAICompatibleURL
        case .anthropic:
            AppConstants.anthropicMessagesURL
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAICompatible:
            AppConstants.fullModel
        case .anthropic:
            AppConstants.anthropicModel
        }
    }

    public var endpointPlaceholder: String {
        switch self {
        case .openAICompatible:
            AppConstants.openAICompatibleURL.absoluteString
        case .anthropic:
            AppConstants.anthropicMessagesURL.absoluteString
        }
    }
}

public struct AIProviderConfiguration: Codable, Equatable, Sendable {
    public let provider: AIProvider
    public let endpoint: URL
    public let model: String

    public init(provider: AIProvider, endpoint: URL, model: String) {
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
    }

    public static func defaultConfiguration(for provider: AIProvider) -> Self {
        Self(
            provider: provider,
            endpoint: provider.defaultEndpoint,
            model: provider.defaultModel
        )
    }

    public var validationMessage: String? {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            return "Enter a model ID."
        }
        guard trimmedModel.count <= 256 else {
            return "The model ID is too long."
        }
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = endpoint.host,
              !host.isEmpty,
              endpoint.user == nil,
              endpoint.password == nil
        else {
            return "Enter a valid http(s) endpoint without embedded credentials."
        }
        return nil
    }

    public var summary: String {
        Self.shortenedModelName(model)
    }

    public static func shortenedModelName(_ model: String) -> String {
        let pattern = #"-(?:\d{4}-\d{2}-\d{2}|\d{8})$"#
        var shortened = model.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
        if shortened.count > 24 {
            shortened = String(shortened.prefix(22)) + "…"
        }
        return shortened
    }
}
