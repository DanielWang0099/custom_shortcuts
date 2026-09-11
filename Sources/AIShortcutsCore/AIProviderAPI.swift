import Foundation

public struct AIProviderClient: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.transport = transport
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

        guard JSONSerialization.isValidJSONObject(body),
              let encoded = try? JSONSerialization.data(withJSONObject: body)
        else {
            throw ResponsesAPIError.invalidRequest
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
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
            let sanitized = AIOutputDocumentSanitizer.sanitizeGlitchMarkers(text)
            let detectedFormat = AIOutputFormatDetector.detect(sanitized)
            let format = allowedOutputFormats.contains(detectedFormat)
                ? detectedFormat
                : (allowedOutputFormats.first ?? .plainText)
            let fallbackDoc = AIOutputDocument(format: format, source: sanitized)
            if (try? AIOutputDocumentValidator.validate(fallbackDoc)) != nil {
                output = fallbackDoc
            } else {
                output = AIOutputDocument(format: .plainText, source: sanitized)
            }
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
            let sanitized = AIOutputDocumentSanitizer.sanitizeGlitchMarkers(text)
            let detectedFormat = AIOutputFormatDetector.detect(sanitized)
            let format = allowedOutputFormats.contains(detectedFormat)
                ? detectedFormat
                : (allowedOutputFormats.first ?? .plainText)
            let fallbackDoc = AIOutputDocument(format: format, source: sanitized)
            if (try? AIOutputDocumentValidator.validate(fallbackDoc)) != nil {
                output = fallbackDoc
            } else {
                output = AIOutputDocument(format: .plainText, source: sanitized)
            }
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
