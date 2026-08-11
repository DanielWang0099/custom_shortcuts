public struct ClipboardQueueCopyPressTracker {
    private var isDown = false

    public init() {}

    public mutating func beginKeyDown() -> Bool {
        guard !isDown else {
            return false
        }
        isDown = true
        return true
    }

    public mutating func endKeyUp() -> Bool {
        guard isDown else {
            return false
        }
        isDown = false
        return true
    }

    public mutating func reset() {
        isDown = false
    }
}
