import Foundation

public struct DailyBudgetState: Codable, Equatable, Sendable {
    public var utcDay: String
    public var reservedTokens: Int

    public init(utcDay: String, reservedTokens: Int) {
        self.utcDay = utcDay
        self.reservedTokens = reservedTokens
    }
}

public enum BudgetReservationResult: Equatable, Sendable {
    case reserved(DailyBudgetState)
    case refused(remaining: Int, requested: Int)
}

public struct DailyBudgetLedger: Sendable {
    public let limit: Int
    public private(set) var state: DailyBudgetState

    public init(
        limit: Int,
        state: DailyBudgetState? = nil,
        now: Date = Date()
    ) {
        self.limit = limit
        let day = Self.utcDay(for: now)
        if let state, state.utcDay == day {
            self.state = DailyBudgetState(
                utcDay: day,
                reservedTokens: min(limit, max(0, state.reservedTokens))
            )
        } else {
            self.state = DailyBudgetState(utcDay: day, reservedTokens: 0)
        }
    }

    public var remaining: Int {
        max(0, limit - state.reservedTokens)
    }

    public mutating func reserve(_ requested: Int, now: Date = Date()) -> BudgetReservationResult {
        normalize(now: now)
        let amount = max(0, requested)
        guard amount <= remaining else {
            return .refused(remaining: remaining, requested: amount)
        }
        state.reservedTokens += amount
        return .reserved(state)
    }

    public mutating func normalize(now: Date = Date()) {
        let day = Self.utcDay(for: now)
        guard state.utcDay != day else {
            return
        }
        state = DailyBudgetState(utcDay: day, reservedTokens: 0)
    }

    public static func utcDay(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public enum TokenEstimator {
    public static func textReservation(for prompt: PromptSpec) -> Int {
        prompt.instructions.utf8.count
            + prompt.inputText.utf8.count
            + prompt.maxOutputTokens
            + AppConstants.budgetSafetyMargin
    }

    public static func imageReservation(
        for prompt: PromptSpec,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Int {
        let patchesWide = max(1, Int(ceil(Double(max(1, pixelWidth)) / 32.0)))
        let patchesHigh = max(1, Int(ceil(Double(max(1, pixelHeight)) / 32.0)))
        let imagePatches = patchesWide * patchesHigh
        return prompt.instructions.utf8.count
            + prompt.inputText.utf8.count
            + imagePatches
            + prompt.maxOutputTokens
            + AppConstants.budgetSafetyMargin
    }

    public static func multimodalReservation(
        for prompt: PromptSpec,
        pixelSizes: [(width: Int, height: Int)]
    ) -> Int {
        let imagePatches = pixelSizes.reduce(0) { total, size in
            let patchesWide = max(1, Int(ceil(Double(max(1, size.width)) / 32.0)))
            let patchesHigh = max(1, Int(ceil(Double(max(1, size.height)) / 32.0)))
            return total + (patchesWide * patchesHigh)
        }
        return prompt.instructions.utf8.count
            + prompt.inputText.utf8.count
            + imagePatches
            + prompt.maxOutputTokens
            + AppConstants.budgetSafetyMargin
    }
}
