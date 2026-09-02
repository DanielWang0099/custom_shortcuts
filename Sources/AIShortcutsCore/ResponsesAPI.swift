import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private static let idleSessionLifetime: TimeInterval = 8

    private let stateLock = NSLock()
    private let managesSessionLifecycle: Bool
    private var session: URLSession?
    private var lastUsedAt: Date?

    public init() {
        managesSessionLifecycle = true
        session = nil
        lastUsedAt = nil
    }

    public init(session: URLSession) {
        managesSessionLifecycle = false
        self.session = session
        lastUsedAt = nil
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let activeSession = sessionForRequest()
        do {
            return try await activeSession.data(for: request)
        } catch {
            if NetworkRetryPolicy.shouldRetry(error) {
                discardManagedSession(activeSession)
            }
            throw error
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }

    private func sessionForRequest(now: Date = Date()) -> URLSession {
        stateLock.lock()
        defer { stateLock.unlock() }

        if !managesSessionLifecycle, let session {
            return session
        }
        if let session,
           let lastUsedAt,
           now.timeIntervalSince(lastUsedAt) < Self.idleSessionLifetime
        {
            self.lastUsedAt = now
            return session
        }

        session?.finishTasksAndInvalidate()
        let replacement = Self.makeSession()
        session = replacement
        lastUsedAt = now
        return replacement
    }

    private func discardManagedSession(_ failedSession: URLSession) {
        guard managesSessionLifecycle else {
            return
        }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard session === failedSession else {
            return
        }
        failedSession.invalidateAndCancel()
        session = nil
        lastUsedAt = nil
    }
}

public enum NetworkRetryPolicy {
    public static func shouldRetry(_ error: Error) -> Bool {
        guard let networkError = error as? URLError else {
            return false
        }
        return networkError.code == .networkConnectionLost
    }
}

public struct AICompletion: Equatable, Sendable {
    public let text: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int

    public init(
        text: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int
    ) {
        self.text = text
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

public enum ResponsesAPIError: LocalizedError, Equatable, Sendable {
    case invalidRequest
    case invalidHTTPResponse
    case httpStatus(Int, String)
    case incomplete(String)
    case refusal(String)
    case missingOutput
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The OpenAI request could not be encoded."
        case .invalidHTTPResponse:
            "OpenAI returned an invalid network response."
        case let .httpStatus(status, message):
            message.isEmpty ? "OpenAI returned HTTP \(status)." : message
        case let .incomplete(reason):
            reason.isEmpty ? "OpenAI did not complete the response." : "OpenAI did not complete the response: \(reason)"
        case let .refusal(message):
            message.isEmpty ? "OpenAI declined this request." : message
        case .missingOutput:
            "OpenAI returned no text."
        case .malformedResponse:
            "OpenAI returned an unreadable response."
        }
    }
}

public struct ResponsesAPIClient: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    public func makeRequest(
        prompt: PromptSpec,
        imagePNGs: [Data],
        apiKey: String,
        safetyIdentifier: String
    ) throws -> URLRequest {
        var content: [[String: Any]] = [
            [
                "type": "input_text",
                "text": prompt.inputText,
            ],
        ]
        for imagePNG in imagePNGs {
            content.append([
                "type": "input_image",
                "image_url": "data:image/png;base64,\(imagePNG.base64EncodedString())",
                "detail": "original",
            ])
        }

        var textOptions: [String: Any] = [
            "verbosity": "low",
        ]
        if let outputSchema = prompt.outputSchema {
            textOptions["format"] = Self.textFormat(for: outputSchema)
        }

        let body: [String: Any] = [
            "model": prompt.model,
            "instructions": prompt.instructions,
            "input": [
                [
                    "role": "user",
                    "content": content,
                ],
            ],
            "reasoning": [
                "effort": prompt.reasoningEffort.rawValue,
            ],
            "text": textOptions,
            "max_output_tokens": prompt.maxOutputTokens,
            "store": false,
            "safety_identifier": safetyIdentifier,
        ]

        guard JSONSerialization.isValidJSONObject(body),
              let encoded = try? JSONSerialization.data(withJSONObject: body)
        else {
            throw ResponsesAPIError.invalidRequest
        }

        var request = URLRequest(url: AppConstants.responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = encoded
        return request
    }

    public func complete(
        prompt: PromptSpec,
        imagePNGs: [Data] = [],
        apiKey: String,
        safetyIdentifier: String
    ) async throws -> AICompletion {
        let request = try makeRequest(
            prompt: prompt,
            imagePNGs: imagePNGs,
            apiKey: apiKey,
            safetyIdentifier: safetyIdentifier
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
            let message = Self.parseAPIErrorMessage(from: data)
            throw ResponsesAPIError.httpStatus(http.statusCode, message)
        }
        return try Self.parseCompletion(
            from: data,
            fallbackModel: prompt.model
        )
    }

    public static func parseCompletion(
        from data: Data,
        fallbackModel: String = AppConstants.fullModel
    ) throws -> AICompletion {
        let response: ResponseEnvelope
        do {
            response = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            throw ResponsesAPIError.malformedResponse
        }

        let allContent = response.output
            .compactMap(\.content)
            .reduce(into: [OutputContent]()) { result, content in
                result.append(contentsOf: content)
            }

        if let refusal = allContent
            .first(where: { $0.type == "refusal" })?
            .refusal {
            throw ResponsesAPIError.refusal(refusal)
        }

        guard response.status == nil || response.status == "completed" else {
            throw ResponsesAPIError.incomplete(response.incompleteDetails?.reason ?? "")
        }

        let fragments = allContent
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
        guard !fragments.isEmpty else {
            throw ResponsesAPIError.missingOutput
        }

        let usage = response.usage
        return AICompletion(
            text: fragments.joined(separator: "\n"),
            model: response.model ?? fallbackModel,
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0,
            totalTokens: usage?.totalTokens ?? 0
        )
    }

    private static func textFormat(for schema: OutputSchema) -> [String: Any] {
        switch schema {
        case .calculateAnswer:
            return [
                "type": "json_schema",
                "name": "calculate_answer",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "answer": [
                            "type": "string",
                            "description": "The final useful answer only, with no reasoning or work shown.",
                        ],
                    ],
                    "required": ["answer"],
                    "additionalProperties": false,
                ],
            ]
        }
    }

    private static func parseAPIErrorMessage(from data: Data) -> String {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message ?? ""
    }
}

private struct ResponseEnvelope: Decodable {
    let status: String?
    let model: String?
    let output: [OutputItem]
    let usage: Usage?
    let incompleteDetails: IncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case status
        case model
        case output
        case usage
        case incompleteDetails = "incomplete_details"
    }
}

private struct OutputItem: Decodable {
    let content: [OutputContent]?
}

private struct OutputContent: Decodable {
    let type: String
    let text: String?
    let refusal: String?
}

private struct Usage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct IncompleteDetails: Decodable {
    let reason: String?
}

private struct ErrorEnvelope: Decodable {
    let error: ErrorBody
}

private struct ErrorBody: Decodable {
    let message: String
}
