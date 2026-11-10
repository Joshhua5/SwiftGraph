import Foundation

/// Rectangle quadtree. Straddling and out-of-root entries remain in the parent bucket.
public final class QuadTree<Value> {
    private let bounds: Rect
    private let capacity: Int
    private let maxDepth: Int
    private var entries: [(Rect, Value)] = []
    private var children: [QuadTree<Value>] = []

    public init(bounds: Rect, capacity: Int = 32, maxDepth: Int = 8) {
        self.bounds = bounds
        self.capacity = max(1, capacity)
        self.maxDepth = max(0, maxDepth)
    }

    public func insert(bounds rect: Rect, item: Value) {
        if let child = child(for: rect) {
            child.insert(bounds: rect, item: item)
            return
        }
        entries.append((rect, item))
        if children.isEmpty && entries.count > capacity && maxDepth > 0 && bounds.width > 0 && bounds.height > 0 {
            let halfW = bounds.width / 2
            let halfH = bounds.height / 2
            children = [(Float(1), Float(0)), (0, 0), (0, 1), (1, 1)]
                .map { x, y in
                    QuadTree(
                        bounds: Rect(x: bounds.x + x * halfW, y: bounds.y + y * halfH, width: halfW, height: halfH),
                        capacity: capacity,
                        maxDepth: maxDepth - 1
                    )
                }
            let old = entries
            entries = []
            for (r, value) in old.reversed() {
                if let child = child(for: r) {
                    child.insert(bounds: r, item: value)
                } else {
                    entries.append((r, value))
                }
            }
        }
    }

    private func encloses(_ r: Rect) -> Bool {
        bounds.left <= r.left && bounds.right >= r.right && bounds.top <= r.top && bounds.bottom >= r.bottom
    }

    private func child(for r: Rect) -> QuadTree<Value>? {
        guard !children.isEmpty else { return nil }
        let mid = bounds.center
        let top = r.y < mid.y && r.bottom < mid.y
        let bottom = r.y > mid.y
        let quadrant: Int
        if r.x < mid.x && r.right < mid.x {
            if top { quadrant = 1 } else if bottom { quadrant = 2 } else { return nil }
        } else if r.x > mid.x {
            if top { quadrant = 0 } else if bottom { quadrant = 3 } else { return nil }
        } else {
            return nil
        }
        return children[quadrant].encloses(r) ? children[quadrant] : nil
    }

    public func query(_ area: Rect) -> [Value] {
        var result: [Value] = []
        var stack = [self]
        while let node = stack.popLast() {
            for (r, value) in node.entries.reversed() where r.intersects(area) { result.append(value) }
            stack.append(contentsOf: node.children.filter { $0.bounds.intersects(area) })
        }
        return result
    }

    public func query(_ area: Rect, results: inout [Value]) {
        for (r, value) in entries.reversed() where r.intersects(area) { results.append(value) }
        for child in children where child.bounds.intersects(area) { child.query(area, results: &results) }
    }

    /// Whether any entry touching `area` satisfies `predicate`. Stops at the first match and allocates nothing.
    public func contains(intersecting area: Rect, where predicate: (Rect, Value) -> Bool) -> Bool {
        for (r, value) in entries where r.intersects(area) && predicate(r, value) { return true }
        for child in children where child.bounds.intersects(area) {
            if child.contains(intersecting: area, where: predicate) { return true }
        }
        return false
    }

    /// Visits every entry touching `area`, in no particular order, without allocating.
    public func forEach(intersecting area: Rect, _ body: (Rect, Value) -> Void) {
        for (r, value) in entries where r.intersects(area) { body(r, value) }
        for child in children where child.bounds.intersects(area) { child.forEach(intersecting: area, body) }
    }
}
