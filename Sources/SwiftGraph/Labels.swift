import Foundation

/// Swift payloads can opt into labeling without reflection or coupling to a UI framework.
public protocol GraphLabelData { var label: String { get } }
public final class LabelPlacementAlgorithm {
    public var labelProvider: (LayoutEdge) -> String? = { edge in
        if let value = edge.data as? any GraphLabelData { return value.label }
        if let value = edge.data as? String { return value }
        if let value = edge.data as? [String: String] { return value["Label"] ?? value["label"] }
        return nil
    }
    public init() {}
    public func applyLabelPlacement(_ graph: LayoutGraph) {
        let tree = QuadTree<LayoutNode>(bounds: graph.bounds.inflated(by: 500))
        for node in graph.nodes where !node.isGroup { tree.insert(bounds: node.bounds, item: node) }
        for edge in graph.edges {
            guard let text = labelProvider(edge), !text.isEmpty else { continue }
            let width = Double(text.count * 8 + 10), height = 20.0
            let mid = max(0, (edge.path.count - 1) / 2)
            let center = edge.path.count >= 2 ? (edge.path[mid] + edge.path[mid + 1]) / 2 : .zero
            edge.labelBounds = Rect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            for _ in 0..<10 {
                if tree.query(edge.labelBounds).isEmpty { break }
                edge.labelBounds.y -= 5
            }
        }
    }
}

public final class LabelLayoutAlgorithm {
    public var iterations = 200
    public init() {}
    public func applyLabelLayout(_ graph: LayoutGraph) {
        let edges = graph.edges
        guard !edges.isEmpty else { return }
        let obstacles = graph.nodes.filter { !$0.isGroup }.map(\.bounds)
        for e in edges {
            if e.labelBounds.width == 0 { e.labelBounds = Rect(width: Double("Edge[\(e.source.id) -> \(e.target.id)]".count * 8), height: 20) }
            if let first = e.path.first, let last = e.path.last, e.path.count >= 2 {
                let center = (first + last) / 2
                e.labelBounds.x = center.x - e.labelBounds.width / 2; e.labelBounds.y = center.y - e.labelBounds.height / 2
            }
        }
        func energy() -> Double {
            var result = 0.0
            for (i, e) in edges.enumerated() {
                result += Double(obstacles.filter { $0.intersects(e.labelBounds) }.count) * 1000
                for j in edges.indices where i != j && e.labelBounds.intersects(edges[j].labelBounds) { result += 100 }
                if e.path.count >= 2 {
                    let c = e.labelBounds.center
                    result += (e.path.map { abs($0.x - c.x) + abs($0.y - c.y) }.min() ?? 0) * 0.1
                }
            }
            return result
        }
        var random = SeededRandom(state: 123), temperature = 100.0, current = energy()
        for _ in 0..<max(0, iterations) {
            if Task.isCancelled { return }
            let edge = edges[Int(random.next() * Double(edges.count))], old = edge.labelBounds
            edge.labelBounds.x += (random.next() - 0.5) * temperature; edge.labelBounds.y += (random.next() - 0.5) * temperature
            let candidate = energy()
            if candidate < current || random.next() <= exp((current - candidate) / max(temperature, 1e-12)) { current = candidate }
            else { edge.labelBounds = old }
            temperature *= 0.95
        }
    }
}
