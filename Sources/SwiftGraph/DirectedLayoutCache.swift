import Foundation

/// Bounded, value-only component cache. Graph objects are never retained or shared between tasks.
public final class DirectedLayoutCache: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var values: [DirectedComponentKey: DirectedComponentDrawing] = [:]
    private var order: [DirectedComponentKey] = []
    public init(capacity: Int = 64) { self.capacity = max(0, capacity) }
    public func removeAll() { lock.lock(); defer { lock.unlock() }; values.removeAll(); order.removeAll() }
    func drawing(for key: DirectedComponentKey) -> DirectedComponentDrawing? {
        lock.lock(); defer { lock.unlock() }
        guard let drawing = values[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return drawing
    }
    func insert(_ drawing: DirectedComponentDrawing, for key: DirectedComponentKey) {
        lock.lock(); defer { lock.unlock() }
        guard capacity > 0 else { return }
        order.removeAll { $0 == key }; order.append(key); values[key] = drawing
        while order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
    }
}

struct DirectedComponentKey: Hashable {
    struct Node: Hashable { var id: String; var width: Float; var height: Float }
    struct Edge: Hashable { var source: String; var target: String; var sourcePort: PortConstraint; var targetPort: PortConstraint; var index: Int }
    var nodes: [Node]
    var edges: [Edge]
    var configuration: DirectedLayoutConfiguration
}

struct DirectedComponentDrawing {
    var bounds: [Rect]
    var paths: [[Point]]
    var score: DirectedGeometry.Score
}
