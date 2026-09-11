public struct FIFOQueue<Element> {
    private var storage: [Element] = []

    public init() {}

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func enqueue(_ element: Element) {
        storage.append(element)
    }

    public mutating func dequeue() -> Element? {
        guard !storage.isEmpty else {
            return nil
        }
        return storage.removeFirst()
    }

    public mutating func reset() {
        storage.removeAll(keepingCapacity: false)
    }
}

extension FIFOQueue: Sendable where Element: Sendable {}


public struct ClipboardQueuePasteSession<Element> {
    public private(set) var current: Element?
    private var remainingQueue: FIFOQueue<Element>

    public init(queue: inout FIFOQueue<Element>) {
        self.current = queue.dequeue()
        self.remainingQueue = queue
        queue.reset()
    }

    public var count: Int {
        (current != nil ? 1 : 0) + remainingQueue.count
    }

    public var isComplete: Bool {
        current == nil && remainingQueue.isEmpty
    }

    @discardableResult
    public mutating func advance() -> Element? {
        current = remainingQueue.dequeue()
        return current
    }
}

extension ClipboardQueuePasteSession: Sendable where Element: Sendable {}
