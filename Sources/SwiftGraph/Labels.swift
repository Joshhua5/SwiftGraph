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
        var labeled: [LayoutEdge] = []
        for edge in graph.edges {
            guard let text = labelProvider(edge), !text.isEmpty else { continue }
            labeled.append(edge)
            let width = Double(text.count * 8 + 10), height = 20.0
            let center = LabelCollisionRepair.midpoint(edge.path)
            edge.labelBounds = Rect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            for _ in 0..<10 {
                if (RoutingCompute.current.map { $0.intersections(edge.labelBounds, graph.nodes.filter { !$0.isGroup }.map(\.bounds)).isEmpty } ?? tree.query(edge.labelBounds).isEmpty) { break }
                edge.labelBounds.y -= 5
            }
        }
        LabelCollisionRepair.apply(labeled, obstacles: graph.nodes.filter { !$0.isGroup }.map(\.bounds))
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
            if e.path.count >= 2 {
                let center = LabelCollisionRepair.midpoint(e.path)
                e.labelBounds.x = center.x - e.labelBounds.width / 2; e.labelBounds.y = center.y - e.labelBounds.height / 2
            }
        }
        func energy() -> Double {
            var result = 0.0
            let rectangles = edges.map(\.labelBounds)
            let obstacleFlags = RoutingCompute.current?.candidates(rectangles, obstacles)
            let labelFlags = RoutingCompute.current?.candidates(rectangles, rectangles)
            for (i, e) in edges.enumerated() {
                result += Double(obstacles.indices.filter { j in (obstacleFlags?[i * obstacles.count + j] ?? 1) != 0 && obstacles[j].intersects(e.labelBounds) }.count) * 1000
                for j in edges.indices where i != j && (labelFlags?[i * edges.count + j] ?? 1) != 0 && e.labelBounds.intersects(edges[j].labelBounds) { result += 100 }
                if e.path.count >= 2 {
                    let c = e.labelBounds.center
                    result += LabelCollisionRepair.distance(c, to: e.path) * 0.1
                }
            }
            return result
        }
        var random = SeededRandom(state: 123), temperature = 100.0, current = energy()
        var best = current, bestBounds = edges.map(\.labelBounds)
        for _ in 0..<max(0, iterations) {
            if RoutingCompute.isCancelled { return }
            let edge = edges[Int(random.next() * Double(edges.count))], old = edge.labelBounds
            edge.labelBounds.x += (random.next() - 0.5) * temperature; edge.labelBounds.y += (random.next() - 0.5) * temperature
            let candidate = energy()
            if candidate < current || random.next() <= exp((current - candidate) / max(temperature, 1e-12)) { current = candidate }
            else { edge.labelBounds = old }
            if current < best { best = current; bestBounds = edges.map(\.labelBounds) }
            temperature *= 0.95
        }
        for (edge, bounds) in zip(edges, bestBounds) { edge.labelBounds = bounds }
        LabelCollisionRepair.apply(edges, obstacles: obstacles)
    }
}

private enum LabelCollisionRepair {
    static func midpoint(_ path: [Point]) -> Point {
        let segments = Array(zip(path, path.dropFirst()))
        var remaining = segments.reduce(0.0) { $0 + ($1.1 - $1.0).length } / 2
        for (a, b) in segments {
            let length = (b - a).length
            if length > 0 && remaining <= length { return a + (b - a) * (remaining / length) }
            remaining -= length
        }
        return path.first ?? .zero
    }
    static func distance(_ point: Point, to path: [Point]) -> Double {
        zip(path, path.dropFirst()).map { a, b in
            let delta = b - a
            let t = delta.lengthSquared > 0 ? max(0, min(1, ((point.x - a.x) * delta.x + (point.y - a.y) * delta.y) / delta.lengthSquared)) : 0
            return (point - (a + delta * t)).length
        }.min() ?? path.first.map { (point - $0).length } ?? 0
    }
    static func apply(_ edges: [LayoutEdge], obstacles: [Rect]) {
        for _ in 0..<8 {
            var changed = false
            for (index, edge) in edges.enumerated() where edge.labelBounds.width > 0 && edge.labelBounds.height > 0 {
                if RoutingCompute.isCancelled { return }
                let original = edge.labelBounds
                let labelRects = edges.map(\.labelBounds)
                var candidates = [original]
                for (a, b) in zip(edge.path, edge.path.dropFirst()) {
                    let delta = b - a
                    guard delta.length > 1e-9 else { continue }
                    let normal = Point(x: -delta.y, y: delta.x) / delta.length
                    let clearance = abs(normal.x) * original.width / 2 + abs(normal.y) * original.height / 2 + 4
                    for t in [0.5, 0.25, 0.75] {
                        for offset in [0.0, 1, -1, 2, -2, 3, -3] {
                            let center = a + delta * t + normal * (offset * clearance)
                            candidates.append(Rect(x: center.x - original.width / 2, y: center.y - original.height / 2, width: original.width, height: original.height))
                        }
                    }
                }
                let obstacleFlags = RoutingCompute.current?.candidates(candidates, obstacles)
                let labelFlags = RoutingCompute.current?.candidates(candidates, labelRects)
                func score(_ i: Int) -> [Double] {
                    let rect = candidates[i]
                    return [Double(obstacles.indices.filter { j in (obstacleFlags?[i * obstacles.count + j] ?? 1) != 0 && obstacles[j].intersects(rect) }.count),
                            Double(edges.indices.filter { j in j != index && (labelFlags?[i * edges.count + j] ?? 1) != 0 && labelRects[j].intersects(rect) }.count),
                            distance(rect.center, to: edge.path), (rect.center - original.center).lengthSquared]
                }
                var best = original, bestScore = score(0)
                if bestScore[0] == 0 && bestScore[1] == 0 { continue }
                for i in candidates.indices.dropFirst() {
                    let candidate = score(i)
                    if candidate.lexicographicallyPrecedes(bestScore) { best = candidates[i]; bestScore = candidate }
                }
                if best != original { edge.labelBounds = best; changed = true }
            }
            if !changed { break }
        }
    }
}
