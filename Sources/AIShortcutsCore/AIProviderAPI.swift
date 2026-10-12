import Foundation

public struct AIProviderClient: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    public func prepareConnection() {
        transport.prepare()
    }

    public func preconnect(to endpoint: URL) async {
        await transport.preconnect(to: endpoint)
    }

    public func suspendConnection() {
        transport.suspend()
    }

    public func makeRequest(
        prompt: PromptSpec,
        imagePNGs: [Data] = [],
        apiKey: String,
        safetyIdentifier: String,
        configuration: AIProviderConfiguration
    ) throws -> URLRequest {
        guard configuration.validationMessage == nil else {
            throw ResponsesAPIError.invalidRequest
        }

        let body: [String: Any]
        switch configuration.provider {
        case .openAICompatible:
            body = openAICompatibleBody(
                prompt: prompt,
                imagePNGs: imagePNGs,
                configuration: configuration
            )
        case .anthropic:
            body = anthropicBody(
                prompt: prompt,
                imagePNGs: imagePNGs,
                configuration: configuration
            )
        }

        let encoded: Data
        do {
            encoded = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ResponsesAPIError.invalidRequest
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.networkServiceType = .responsiveData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch configuration.provider {
        case .openAICompatible:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = encoded
        _ = safetyIdentifier
        return request
    }

    public func complete(
        prompt: PromptSpec,
        imagePNGs: [Data] = [],
        apiKey: String,
        safetyIdentifier: String,
        configuration: AIProviderConfiguration
    ) async throws -> AICompletion {
        let request = try makeRequest(
            prompt: prompt,
            imagePNGs: imagePNGs,
            apiKey: apiKey,
            safetyIdentifier: safetyIdentifier,
            configuration: configuration
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            guard NetworkRetryPolicy.shouldRetry(error), !Task.isCancelled else {
                throw error
            }
            try await Task.sleep(for: .milliseconds(120))
            (data, response) = try await transport.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ResponsesAPIError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ResponsesAPIError.httpStatus(http.statusCode, parseAPIErrorMessage(from: data))
        }

        switch configuration.provider {
        case .openAICompatible:
            return try parseOpenAICompatibleCompletion(
                from: data,
                fallbackModel: configuration.model,
                outputSchema: prompt.outputSchema,
                allowedOutputFormats: prompt.allowedOutputFormats
            )
        case .anthropic:
            return try parseAnthropicCompletion(
                from: data,
                fallbackModel: configuration.model,
                outputSchema: prompt.outputSchema,
                allowedOutputFormats: prompt.allowedOutputFormats
            )
        }
    }

    /// Builds a typed dictionary request for an OpenAI-compatible or
    /// Anthropic endpoint. The dictionary schema is intentionally separate
    /// from the regular shortcut output schemas so adding it cannot alter
    /// existing `complete()` requests.
    public func makeDictionaryRequest(
        request dictionaryRequest: DictionaryAIRequest,
        apiKey: String,
        safetyIdentifier: String,
        configuration: AIProviderConfiguration
    ) throws -> URLRequest {
        guard configuration.validationMessage == nil,
              dictionaryRequest.validationMessage == nil
        else {
            throw ResponsesAPIError.invalidRequest
        }

        let body: [String: Any]
        switch configuration.provider {
        case .openAICompatible:
            body = openAICompatibleDictionaryBody(
                request: dictionaryRequest,
                configuration: configuration
            )
        case .anthropic:
            body = anthropicDictionaryBody(
                request: dictionaryRequest,
                configuration: configuration
            )
        }

        let encoded: Data
        do {
            encoded = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ResponsesAPIError.invalidRequest
        }

        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.networkServiceType = .responsiveData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch configuration.provider {
        case .openAICompatible:
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        urlRequest.httpBody = encoded
        _ = safetyIdentifier
        return urlRequest
    }

    /// Requests one of the two deliberately small dictionary AI contracts:
    /// sentence translation/context, or focused entry enrichment.
    public func completeDictionary(
        request dictionaryRequest: DictionaryAIRequest,
        apiKey: String,
        safetyIdentifier: String,
        configuration: AIProviderConfiguration
    ) async throws -> DictionaryAIResponse {
        let urlRequest = try makeDictionaryRequest(
            request: dictionaryRequest,
            apiKey: apiKey,
            safetyIdentifier: safetyIdentifier,
            configuration: configuration
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: urlRequest)
        } catch {
            guard NetworkRetryPolicy.shouldRetry(error), !Task.isCancelled else {
                throw error
            }
            try await Task.sleep(for: .milliseconds(120))
            (data, response) = try await transport.data(for: urlRequest)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ResponsesAPIError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ResponsesAPIError.httpStatus(http.statusCode, parseAPIErrorMessage(from: data))
        }

        let text: String
        switch configuration.provider {
        case .openAICompatible:
            text = try parseOpenAICompatibleCompletion(
                from: data,
                fallbackModel: configuration.model,
                outputSchema: nil,
                allowedOutputFormats: []
            ).text
        case .anthropic:
            text = try parseAnthropicCompletion(
                from: data,
                fallbackModel: configuration.model,
                outputSchema: nil,
                allowedOutputFormats: []
            ).text
        }

        let responseData = AIOutputDocumentSanitizer.extractJSONPayload(from: text) ?? Data(text.utf8)
        let dictionaryResponse: DictionaryAIResponse
        do {
            dictionaryResponse = try JSONDecoder().decode(DictionaryAIResponse.self, from: responseData)
        } catch {
            throw ResponsesAPIError.invalidOutput(
                "The AI provider returned an invalid dictionary answer."
            )
        }
        try validateDictionaryResponse(dictionaryResponse, for: dictionaryRequest)
        return dictionaryResponse
    }

    private func openAICompatibleBody(
        prompt: PromptSpec,
        imagePNGs: [Data],
        configuration: AIProviderConfiguration
    ) -> [String: Any] {
        var userContent: [[String: Any]] = [
            [
                "type": "text",
                "text": prompt.inputText,
            ],
        ]
        for imagePNG in imagePNGs {
            userContent.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/png;base64,\(imagePNG.base64EncodedString())",
                    "detail": "high",
                ],
            ])
        }

        var body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                [
                    "role": "system",
                    "content": prompt.instructions,
                ],
                [
                    "role": "user",
                    "content": userContent,
                ],
            ],
            "max_completion_tokens": prompt.maxOutputTokens,
        ]
        if let outputSchema = prompt.outputSchema {
            let format = ResponsesAPIClient.textFormat(
                for: outputSchema,
                allowedOutputFormats: prompt.allowedOutputFormats
            )
            var jsonSchema: [String: Any] = [:]
            for key in ["name", "strict", "schema"] {
                if let value = format[key] {
                    jsonSchema[key] = value
                }
            }
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": jsonSchema,
            ]
        }
        return body
    }

    private func anthropicBody(
        prompt: PromptSpec,
        imagePNGs: [Data],
        configuration: AIProviderConfiguration
    ) -> [String: Any] {
        var userContent: [[String: Any]] = [
            [
                "type": "text",
                "text": prompt.inputText,
            ],
        ]
        for imagePNG in imagePNGs {
            userContent.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": imagePNG.base64EncodedString(),
                ],
            ])
        }

        var body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": max(prompt.maxOutputTokens, 1),
            "system": prompt.instructions,
            "messages": [
                [
                    "role": "user",
                    "content": userContent,
                ],
            ],
        ]
        if let outputSchema = prompt.outputSchema {
            let format = ResponsesAPIClient.textFormat(
                for: outputSchema,
                allowedOutputFormats: prompt.allowedOutputFormats
            )
            if let schema = format["schema"] as? [String: Any] {
                body["output_config"] = [
                    "format": [
                        "type": "json_schema",
                        "schema": schema,
                    ],
                ]
            }
        }
        return body
    }

    private func openAICompatibleDictionaryBody(
        request: DictionaryAIRequest,
        configuration: AIProviderConfiguration
    ) -> [String: Any] {
        [
            "model": configuration.model,
            "messages": [
                [
                    "role": "system",
                    "content": request.promptInstructions,
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": request.promptInputText,
                        ],
                    ],
                ],
            ],
            "max_completion_tokens": request.maxOutputTokens,
            "response_format": [
                "type": "json_schema",
                "json_schema": Self.dictionaryTextFormat(),
            ],
        ]
    }

    private func anthropicDictionaryBody(
        request: DictionaryAIRequest,
        configuration: AIProviderConfiguration
    ) -> [String: Any] {
        let format = Self.dictionaryTextFormat()
        return [
            "model": configuration.model,
            "max_tokens": request.maxOutputTokens,
            "system": request.promptInstructions,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": request.promptInputText,
                        ],
                    ],
                ],
            ],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": format["schema"] as Any,
                ],
            ],
        ]
    }

    private static func dictionaryTextFormat() -> [String: Any] {
        [
            "name": "dictionary_response",
            "strict": true,
            "schema": [
                "type": "object",
                "properties": [
                    "kind": [
                        "type": "string",
                        "enum": ["sentence_context", "entry_enrichment"],
                    ],
                    "translation": [
                        "type": ["string", "null"],
                    ],
                    "segmentation": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "text": [
                                    "type": "string",
                                    "minLength": 1,
                                ],
                                "start_utf16": [
                                    "type": "integer",
                                    "minimum": 0,
                                ],
                                "length_utf16": [
                                    "type": "integer",
                                    "minimum": 1,
                                ],
                                "language": [
                                    "type": ["string", "null"],
                                ],
                            ],
                            "required": ["text", "start_utf16", "length_utf16", "language"],
                            "additionalProperties": false,
                        ],
                        "maxItems": 128,
                    ],
                    "readings": [
                        "type": "array",
                        "items": ["type": "string"],
                        "maxItems": 16,
                    ],
                    "contextual_meaning": [
                        "type": ["string", "null"],
                    ],
                    "target_definitions": [
                        "type": "array",
                        "items": ["type": "string"],
                        "maxItems": 8,
                    ],
                    "example_translations": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "source": ["type": "string"],
                                "translation": ["type": "string"],
                            ],
                            "required": ["source", "translation"],
                            "additionalProperties": false,
                        ],
                        "maxItems": 2,
                    ],
                ],
                "required": [
                    "kind",
                    "translation",
                    "segmentation",
                    "readings",
                    "contextual_meaning",
                    "target_definitions",
                    "example_translations",
                ],
                "additionalProperties": false,
            ],
        ]
    }

    private func validateDictionaryResponse(
        _ response: DictionaryAIResponse,
        for request: DictionaryAIRequest
    ) throws {
        guard response.kind == request.kind else {
            throw ResponsesAPIError.invalidOutput(
                "The AI provider returned the wrong dictionary response kind."
            )
        }
        switch request {
        case let .sentenceContext(sentenceRequest):
            guard let translation = response.translation,
                  !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ResponsesAPIError.invalidOutput(
                    "The AI provider returned no sentence translation."
                )
            }
            guard response.contextualMeaning == nil,
                  response.targetDefinitions.isEmpty,
                  response.exampleTranslations.isEmpty
            else {
                throw ResponsesAPIError.invalidOutput(
                    "The sentence dictionary response contained entry-enrichment fields."
                )
            }
            try validateDictionaryTokens(response.segmentedTokens, within: sentenceRequest.sourceText)
            if !sentenceRequest.includeSegmentation, !response.segmentedTokens.isEmpty {
                throw ResponsesAPIError.invalidOutput(
                    "The AI provider returned segmentation that was not requested."
                )
            }
            if !sentenceRequest.includeReadings, !response.readings.isEmpty {
                throw ResponsesAPIError.invalidOutput(
                    "The AI provider returned readings that were not requested."
                )
            }
        case let .entryEnrichment(entryRequest):
            guard let meaning = response.contextualMeaning,
                  !meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ResponsesAPIError.invalidOutput(
                    "The AI provider returned no contextual dictionary meaning."
                )
            }
            guard response.translation == nil, response.segmentedTokens.isEmpty else {
                throw ResponsesAPIError.invalidOutput(
                    "The entry dictionary response contained sentence-translation fields."
                )
            }
            guard response.exampleTranslations.count <= 2 else {
                throw ResponsesAPIError.invalidOutput(
                    "The AI provider returned more than two example translations."
                )
            }
            try validateDictionaryTokens(response.segmentedTokens, within: entryRequest.sentence)
        }
    }

    private func validateDictionaryTokens(
        _ tokens: [DictionaryToken],
        within source: String
    ) throws {
        let sourceLength = (source as NSString).length
        var previousEnd = 0
        for token in tokens {
            guard token.sourceRange.location >= 0,
                  token.sourceRange.length > 0,
                  token.sourceRange.location <= sourceLength,
                  token.sourceRange.length <= sourceLength - token.sourceRange.location,
                  token.sourceRange.location >= previousEnd,
                  !token.text.isEmpty
            else {
                throw ResponsesAPIError.invalidOutput(
                    "The AI provider returned an invalid token range."
                )
            }
            let sourceToken = (source as NSString).substring(with: token.sourceRange)
            guard sourceToken == token.text else {
                throw ResponsesAPIError.invalidOutput(
                    "The AI provider returned token text that does not match its UTF-16 range."
                )
            }
            previousEnd = token.sourceRange.location + token.sourceRange.length
        }
    }

    private func parseOpenAICompatibleCompletion(
        from data: Data,
        fallbackModel: String,
        outputSchema: OutputSchema?,
        allowedOutputFormats: [AIOutputFormat]
    ) throws -> AICompletion {
        let response: ChatCompletionEnvelope
        do {
            response = try JSONDecoder().decode(ChatCompletionEnvelope.self, from: data)
        } catch {
            throw ResponsesAPIError.malformedResponse
        }
        guard let choice = response.choices.first else {
            throw ResponsesAPIError.missingOutput
        }
        if let refusal = choice.message?.refusal, !refusal.isEmpty {
            throw ResponsesAPIError.refusal(refusal)
        }
        if let finishReason = choice.finishReason,
           finishReason == "length" || finishReason == "max_tokens"
        {
            throw ResponsesAPIError.incomplete(finishReason)
        }
        let textCandidate = choice.message?.content
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text: String
        if !textCandidate.isEmpty {
            text = textCandidate
        } else if let choiceText = choice.text?.trimmingCharacters(in: .whitespacesAndNewlines), !choiceText.isEmpty {
            text = choiceText
        } else if let reasoning = choice.message?.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoning.isEmpty {
            text = reasoning
        } else {
            throw ResponsesAPIError.missingOutput
        }

        let output: AIOutputDocument
        do {
            output = try ResponsesAPIClient.parseOutputDocument(
                from: text,
                schema: outputSchema,
                allowedOutputFormats: allowedOutputFormats
            )
        } catch {
            output = try fallbackOutputDocument(
                from: text,
                allowedOutputFormats: allowedOutputFormats
            )
        }

        let usage = response.usage
        return AICompletion(
            output: output,
            model: response.model ?? fallbackModel,
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0,
            totalTokens: usage?.totalTokens ?? 0
        )
    }

    private func parseAnthropicCompletion(
        from data: Data,
        fallbackModel: String,
        outputSchema: OutputSchema?,
        allowedOutputFormats: [AIOutputFormat]
    ) throws -> AICompletion {
        let response: AnthropicMessageEnvelope
        do {
            response = try JSONDecoder().decode(AnthropicMessageEnvelope.self, from: data)
        } catch {
            throw ResponsesAPIError.malformedResponse
        }
        if response.stopReason == "refusal" {
            throw ResponsesAPIError.refusal("")
        }
        if response.stopReason == "max_tokens" {
            throw ResponsesAPIError.incomplete(response.stopReason ?? "")
        }
        let text = response.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ResponsesAPIError.missingOutput
        }

        let output: AIOutputDocument
        do {
            output = try ResponsesAPIClient.parseOutputDocument(
                from: text,
                schema: outputSchema,
                allowedOutputFormats: allowedOutputFormats
            )
        } catch {
            output = try fallbackOutputDocument(
                from: text,
                allowedOutputFormats: allowedOutputFormats
            )
        }

        let usage = response.usage
        let inputTokens = usage?.inputTokens ?? 0
        let outputTokens = usage?.outputTokens ?? 0
        return AICompletion(
            output: output,
            model: response.model ?? fallbackModel,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: inputTokens + outputTokens
        )
    }

    private func fallbackOutputDocument(
        from text: String,
        allowedOutputFormats: [AIOutputFormat]
    ) throws -> AIOutputDocument {
        let document: AIOutputDocument
        if let extracted = AIOutputDocumentSanitizer.extractTextDocument(from: text) {
            document = extracted
        } else {
            let sanitized = AIOutputDocumentSanitizer.sanitizeGlitchMarkers(text)
            let detectedFormat = AIOutputFormatDetector.detect(sanitized)
            let format = allowedOutputFormats.contains(detectedFormat)
                ? detectedFormat
                : (allowedOutputFormats.first ?? .plainText)
            document = AIOutputDocument(format: format, source: sanitized)
        }

        guard allowedOutputFormats.contains(document.format) else {
            throw ResponsesAPIError.invalidOutput(
                "The AI provider returned a disallowed output format."
            )
        }
        do {
            try AIOutputDocumentValidator.validate(document)
        } catch let error as AIOutputValidationError {
            throw ResponsesAPIError.invalidOutput(error.localizedDescription)
        }
        return document
    }

    private func parseAPIErrorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        return (try? JSONDecoder().decode(DirectErrorEnvelope.self, from: data))?.message ?? ""
    }
}

private struct ChatCompletionEnvelope: Decodable {
    let choices: [ChatChoice]
    let model: String?
    let usage: ChatUsage?
}

private struct ChatChoice: Decodable {
    let message: ChatMessage?
    let text: String?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case text
        case finishReason = "finish_reason"
    }
}

private struct ChatMessage: Decodable {
    let content: [ChatContent]
    let reasoningContent: String?
    let refusal: String?

    enum CodingKeys: String, CodingKey {
        case content
        case reasoningContent = "reasoning_content"
        case refusal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refusal = try container.decodeIfPresent(String.self, forKey: .refusal)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        if let text = try? container.decode(String.self, forKey: .content) {
            content = [ChatContent(type: "text", text: text)]
        } else if let list = try? container.decode([ChatContent].self, forKey: .content) {
            content = list
        } else {
            content = []
        }
    }
}

private struct ChatContent: Decodable {
    let type: String
    let text: String?

    init(type: String, text: String?) {
        self.type = type
        self.text = text
    }
}

private struct ChatUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "prompt_tokens"
        case outputTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct AnthropicMessageEnvelope: Decodable {
    let content: [AnthropicContent]
    let model: String?
    let stopReason: String?
    let usage: AnthropicUsage?

    enum CodingKeys: String, CodingKey {
        case content
        case model
        case stopReason = "stop_reason"
        case usage
    }
}

private struct AnthropicContent: Decodable {
    let type: String
    let text: String?
}

private struct AnthropicUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

private struct ProviderErrorEnvelope: Decodable {
    let error: ProviderErrorBody
}

private struct ProviderErrorBody: Decodable {
    let message: String
}

private struct DirectErrorEnvelope: Decodable {
    let message: String
}
