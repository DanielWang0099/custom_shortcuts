import Foundation

public struct ExplanationExchange: Equatable, Sendable {
    public let highlightedText: String
    public let request: String
    public let explanation: AIOutputDocument

    public init(
        highlightedText: String,
        request: String,
        explanation: String
    ) {
        self.init(
            highlightedText: highlightedText,
            request: request,
            explanation: AIOutputDocument(format: .plainText, source: explanation)
        )
    }

    public init(
        highlightedText: String,
        request: String,
        explanation: AIOutputDocument
    ) {
        self.highlightedText = highlightedText
        self.request = request
        self.explanation = explanation
    }
}

public struct ExplanationConversationMemory: Sendable {
    public let idleTimeout: TimeInterval
    public let maximumExchanges: Int
    public let maximumUTF8Bytes: Int

    public private(set) var exchanges: [ExplanationExchange] = []
    public private(set) var lastUsedAt: Date?

    public init(
        idleTimeout: TimeInterval = 60 * 60,
        maximumExchanges: Int = 6,
        maximumUTF8Bytes: Int = 48_000
    ) {
        self.idleTimeout = idleTimeout
        self.maximumExchanges = maximumExchanges
        self.maximumUTF8Bytes = maximumUTF8Bytes
    }

    public mutating func context(now: Date = Date()) -> String? {
        resetIfIdle(now: now)
        guard !exchanges.isEmpty else {
            return nil
        }
        return exchanges.enumerated().map { index, exchange in
            let request = exchange.request.isEmpty ? "(none)" : exchange.request
            return """
            Exchange \(index + 1)
            Highlighted content:
            \(exchange.highlightedText)
            Request:
            \(request)
            Explanation:
            \(exchange.explanation.source)
            """
        }.joined(separator: "\n\n")
    }

    public mutating func activeExchanges(now: Date = Date()) -> [ExplanationExchange] {
        resetIfIdle(now: now)
        return exchanges
    }

    public mutating func record(
        highlightedText: String,
        request: String,
        explanation: String,
        now: Date = Date()
    ) {
        record(
            highlightedText: highlightedText,
            request: request,
            explanation: AIOutputDocument(format: .plainText, source: explanation),
            now: now
        )
    }

    public mutating func record(
        highlightedText: String,
        request: String,
        explanation: AIOutputDocument,
        now: Date = Date()
    ) {
        resetIfIdle(now: now)
        exchanges.append(
            ExplanationExchange(
                highlightedText: highlightedText,
                request: request,
                explanation: explanation
            )
        )
        lastUsedAt = now
        trimToBounds()
    }

    public mutating func reset() {
        exchanges.removeAll(keepingCapacity: false)
        lastUsedAt = nil
    }

    private mutating func resetIfIdle(now: Date) {
        guard let lastUsedAt,
              now.timeIntervalSince(lastUsedAt) >= idleTimeout else {
            return
        }
        reset()
    }

    private mutating func trimToBounds() {
        while exchanges.count > max(1, maximumExchanges) {
            exchanges.removeFirst()
        }
        while exchanges.count > 1,
              contextByteCount > max(1, maximumUTF8Bytes) {
            exchanges.removeFirst()
        }
    }

    private var contextByteCount: Int {
        exchanges.reduce(0) { total, exchange in
            total
                + exchange.highlightedText.utf8.count
                + exchange.request.utf8.count
                + exchange.explanation.source.utf8.count
                + 128
        }
    }
}
