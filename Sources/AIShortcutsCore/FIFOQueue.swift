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
