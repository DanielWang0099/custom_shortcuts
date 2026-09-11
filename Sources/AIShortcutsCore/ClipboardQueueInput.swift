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

/// Associates pasteboard changes with physical Copy presses without launching
/// one independent observer per press. A single change can satisfy at most one
/// pending press, which prevents several delayed observers from all capturing
/// the newest clipboard value.
public struct ClipboardQueueCaptureTracker {
    public private(set) var observedChangeCount: Int
    public private(set) var pendingCopyCount = 0

    public init(initialChangeCount: Int = 0) {
        observedChangeCount = initialChangeCount
    }

    public var hasPendingCopies: Bool {
        pendingCopyCount > 0
    }

    public mutating func synchronizeIfIdle(to changeCount: Int) {
        guard !hasPendingCopies else {
            return
        }
        observedChangeCount = changeCount
    }

    public mutating func registerCopyPress() {
        pendingCopyCount += 1
    }

    public func canConsume(changeCount: Int) -> Bool {
        hasPendingCopies && changeCount != observedChangeCount
    }

    @discardableResult
    public mutating func consume(changeCount: Int) -> Bool {
        guard canConsume(changeCount: changeCount) else {
            return false
        }
        observedChangeCount = changeCount
        pendingCopyCount -= 1
        return true
    }

    public mutating func discardPendingCopies(observedChangeCount: Int) {
        self.observedChangeCount = observedChangeCount
        pendingCopyCount = 0
    }
}
