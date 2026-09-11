import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func prepare()
    func preconnect(to endpoint: URL) async
    func suspend()
}

public extension HTTPTransport {
    func prepare() {
    }

    func preconnect(to endpoint: URL) async {
        _ = endpoint
    }

    func suspend() {
    }
}

public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private static let preconnectCooldown: TimeInterval = 20

    private let stateLock = NSLock()
    private let managesSessionLifecycle: Bool
    private var session: URLSession?
    private var lastNetworkActivityAt: Date?

    public init() {
        managesSessionLifecycle = true
        session = nil
        lastNetworkActivityAt = nil
    }

    public init(session: URLSession) {
        managesSessionLifecycle = false
        self.session = session
        lastNetworkActivityAt = nil
    }

    deinit {
        if managesSessionLifecycle {
            session?.invalidateAndCancel()
        }
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let activeSession = sessionForRequest(markNetworkActivity: true)
        do {
            let result = try await activeSession.data(for: request)
            markNetworkActivity(for: activeSession)
            return result
        } catch {
            if NetworkRetryPolicy.shouldRetry(error) {
                discardManagedSession(activeSession)
            }
            throw error
        }
    }

    public func prepare() {
        guard managesSessionLifecycle else {
            return
        }
        _ = sessionForRequest(markNetworkActivity: false)
    }

    public func preconnect(to endpoint: URL) async {
        guard managesSessionLifecycle,
              let activeSession = reservePreconnectSession()
        else {
            return
        }

        // HEAD against the endpoint's origin performs DNS, TCP, TLS, and HTTP
        // negotiation without touching a completion route or sending a model
        // request or credentials. The real request can reuse the connection.
        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )
        components?.path = "/"
        components?.percentEncodedQuery = nil
        components?.fragment = nil
        let connectionURL = components?.url ?? endpoint
        var request = URLRequest(
            url: connectionURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 4
        )
        request.httpMethod = "HEAD"
        request.networkServiceType = .responsiveData
        do {
            _ = try await activeSession.data(for: request)
            markNetworkActivity(for: activeSession)
        } catch {
            // Preconnection is advisory. The real request retains its normal
            // error handling and one-shot retry policy.
        }
    }

    public func suspend() {
        guard managesSessionLifecycle else {
            return
        }
        let oldSession = stateLock.withLock { () -> URLSession? in
            let oldSession = session
            session = nil
            lastNetworkActivityAt = nil
            return oldSession
        }
        oldSession?.invalidateAndCancel()
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
        configuration.networkServiceType = .responsiveData
        return URLSession(configuration: configuration)
    }

    private func sessionForRequest(
        markNetworkActivity: Bool,
        now: Date = Date()
    ) -> URLSession {
        stateLock.lock()
        defer { stateLock.unlock() }

        if !managesSessionLifecycle, let session {
            return session
        }
        if let session {
            if markNetworkActivity {
                lastNetworkActivityAt = now
            }
            return session
        }

        let replacement = Self.makeSession()
        session = replacement
        if markNetworkActivity {
            lastNetworkActivityAt = now
        }
        return replacement
    }

    private func reservePreconnectSession(now: Date = Date()) -> URLSession? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let lastNetworkActivityAt,
           now.timeIntervalSince(lastNetworkActivityAt) < Self.preconnectCooldown
        {
            return nil
        }
        let activeSession: URLSession
        if let session {
            activeSession = session
        } else {
            activeSession = Self.makeSession()
            session = activeSession
        }
        lastNetworkActivityAt = now
        return activeSession
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
        lastNetworkActivityAt = nil
    }

    private func markNetworkActivity(
        for activeSession: URLSession,
        now: Date = Date()
    ) {
        guard managesSessionLifecycle else {
            return
        }
        stateLock.withLock {
            guard session === activeSession else {
                return
            }
            lastNetworkActivityAt = now
        }
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
    public let output: AIOutputDocument
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int

    public var text: String {
        output.source
    }

    public init(
        output: AIOutputDocument,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int
    ) {
        self.output = output
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    public init(
        text: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int
    ) {
        self.init(
            output: AIOutputDocument(format: .plainText, source: text),
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens
        )
    }
}

public enum ResponsesAPIError: LocalizedError, Equatable, Sendable {
    case invalidRequest
    case invalidHTTPResponse
    case httpStatus(Int, String)
    case incomplete(String)
    case refusal(String)
    case missingOutput
    case invalidOutput(String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The AI provider request could not be encoded."
        case .invalidHTTPResponse:
            "The AI provider returned an invalid network response."
        case let .httpStatus(status, message):
            message.isEmpty ? "The AI provider returned HTTP \(status)." : message
        case let .incomplete(reason):
            reason.isEmpty ? "The AI provider did not complete the response." : "The AI provider did not complete the response: \(reason)"
        case let .refusal(message):
            message.isEmpty ? "The AI provider declined this request." : message
        case .missingOutput:
            "The AI provider returned no text."
        case let .invalidOutput(message):
            message.isEmpty ? "The AI provider returned an invalid answer." : message
        case .malformedResponse:
            "The AI provider returned an unreadable response."
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
            textOptions["format"] = Self.textFormat(
                for: outputSchema,
                allowedOutputFormats: prompt.allowedOutputFormats
            )
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

        let encoded: Data
        do {
            encoded = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ResponsesAPIError.invalidRequest
        }

        var request = URLRequest(url: AppConstants.responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.networkServiceType = .responsiveData
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
            fallbackModel: prompt.model,
            outputSchema: prompt.outputSchema,
            allowedOutputFormats: prompt.allowedOutputFormats
        )
    }

    public static func parseCompletion(
        from data: Data,
        fallbackModel: String = AppConstants.fullModel,
        outputSchema: OutputSchema? = nil,
        allowedOutputFormats: [AIOutputFormat] = []
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

        if let incompleteDetails = response.incompleteDetails {
            throw ResponsesAPIError.incomplete(incompleteDetails.reason ?? "")
        }
        guard response.status == nil || response.status == "completed" else {
            throw ResponsesAPIError.incomplete("")
        }

        let fragments = allContent
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
        guard !fragments.isEmpty else {
            throw ResponsesAPIError.missingOutput
        }

        let output = try parseOutputDocument(
            from: fragments.joined(separator: "\n"),
            schema: outputSchema,
            allowedOutputFormats: allowedOutputFormats
        )
        let usage = response.usage
        return AICompletion(
            output: output,
            model: response.model ?? fallbackModel,
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0,
            totalTokens: usage?.totalTokens ?? 0
        )
    }

    static func textFormat(
        for schema: OutputSchema,
        allowedOutputFormats: [AIOutputFormat]
    ) -> [String: Any] {
        let formatValues = allowedOutputFormats.map(\.rawValue)
        switch schema {
        case .textDocument:
            return [
                "type": "json_schema",
                "name": "ai_text_document",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "format": [
                            "type": "string",
                            "enum": formatValues,
                        ],
                        "content": [
                            "type": "string",
                        ],
                    ],
                    "required": ["format", "content"],
                    "additionalProperties": false,
                ],
            ]
        case .calculateAnswer:
            return [
                "type": "json_schema",
                "name": "calculate_answer",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "format": [
                            "type": "string",
                            "enum": formatValues,
                        ],
                        "answer": [
                            "type": "string",
                            "description": "The final useful answer only, with no reasoning or work shown.",
                        ],
                    ],
                    "required": ["format", "answer"],
                    "additionalProperties": false,
                ],
            ]
        case .explanationResponse:
            return [
                "type": "json_schema",
                "name": "explanation_response",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "format": [
                            "type": "string",
                            "enum": formatValues,
                        ],
                        "explanation": [
                            "type": "string",
                            "description": "Clear explanation of the concept or text using markdown formatting where helpful.",
                        ],
                    ],
                    "required": ["format", "explanation"],
                    "additionalProperties": false,
                ],
            ]
        }
    }

    static func parseOutputDocument(
        from text: String,
        schema: OutputSchema?,
        allowedOutputFormats: [AIOutputFormat]
    ) throws -> AIOutputDocument {
        guard let schema else {
            let document = AIOutputDocument(format: .plainText, source: text)
            try AIOutputDocumentValidator.validate(document)
            return document
        }
        guard !allowedOutputFormats.isEmpty else {
            throw ResponsesAPIError.invalidOutput("No output formats were allowed for this action.")
        }

        let dataToDecode = AIOutputDocumentSanitizer.extractJSONPayload(from: text) ?? Data(text.utf8)
        do {
            switch schema {
            case .textDocument:
                let envelope = try JSONDecoder().decode(TextDocumentEnvelope.self, from: dataToDecode)
                return try validatedDocument(
                    format: envelope.format,
                    source: envelope.content,
                    allowedOutputFormats: allowedOutputFormats
                )
            case .calculateAnswer:
                let envelope = try JSONDecoder().decode(CalculateDocumentEnvelope.self, from: dataToDecode)
                return try validatedDocument(
                    format: envelope.format,
                    source: envelope.answer,
                    allowedOutputFormats: allowedOutputFormats
                )
            case .explanationResponse:
                let envelope = try JSONDecoder().decode(ExplanationDocumentEnvelope.self, from: dataToDecode)
                return try validatedDocument(
                    format: envelope.format,
                    source: envelope.explanation,
                    allowedOutputFormats: allowedOutputFormats
                )
            }
        } catch let error as ResponsesAPIError {
            throw error
        } catch {
            throw ResponsesAPIError.invalidOutput("The AI provider returned an invalid structured answer.")
        }
    }

    private static func validatedDocument(
        format: AIOutputFormat,
        source: String,
        allowedOutputFormats: [AIOutputFormat]
    ) throws -> AIOutputDocument {
        let initialDoc = AIOutputDocument(format: format, source: source)
        let resolvedDoc = AIOutputDocumentSanitizer.unwrapOrSanitize(initialDoc)
        guard allowedOutputFormats.contains(resolvedDoc.format) else {
            throw ResponsesAPIError.invalidOutput("The AI provider returned a disallowed output format.")
        }
        do {
            try AIOutputDocumentValidator.validate(resolvedDoc)
        } catch let error as AIOutputValidationError {
            throw ResponsesAPIError.invalidOutput(error.localizedDescription)
        }
        return resolvedDoc
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

private struct TextDocumentEnvelope: Decodable {
    let format: AIOutputFormat
    let content: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictObjectCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard keys == ["format", "content"] else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "The text document envelope must contain exactly format and content."
                )
            )
        }
        self.format = try container.decode(
            AIOutputFormat.self,
            forKey: StrictObjectCodingKey(stringValue: "format")!
        )
        self.content = try container.decode(
            String.self,
            forKey: StrictObjectCodingKey(stringValue: "content")!
        )
    }
}

private struct CalculateDocumentEnvelope: Decodable {
    let format: AIOutputFormat
    let answer: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictObjectCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard keys == ["format", "answer"] || keys == ["format", "content"] else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "The calculate envelope must contain format and answer (or content)."
                )
            )
        }
        self.format = try container.decode(
            AIOutputFormat.self,
            forKey: StrictObjectCodingKey(stringValue: "format")!
        )
        if keys.contains("answer") {
            self.answer = try container.decode(
                String.self,
                forKey: StrictObjectCodingKey(stringValue: "answer")!
            )
        } else {
            self.answer = try container.decode(
                String.self,
                forKey: StrictObjectCodingKey(stringValue: "content")!
            )
        }
    }
}

private struct ExplanationDocumentEnvelope: Decodable {
    let format: AIOutputFormat
    let explanation: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictObjectCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard keys == ["format", "explanation"] || keys == ["format", "content"] else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "The explanation envelope must contain format and explanation (or content)."
                )
            )
        }
        self.format = try container.decode(
            AIOutputFormat.self,
            forKey: StrictObjectCodingKey(stringValue: "format")!
        )
        if keys.contains("explanation") {
            self.explanation = try container.decode(
                String.self,
                forKey: StrictObjectCodingKey(stringValue: "explanation")!
            )
        } else {
            self.explanation = try container.decode(
                String.self,
                forKey: StrictObjectCodingKey(stringValue: "content")!
            )
        }
    }
}

private struct StrictObjectCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
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
