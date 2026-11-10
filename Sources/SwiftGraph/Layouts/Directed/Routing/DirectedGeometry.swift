import Foundation

enum DirectedGeometry {
    static let epsilon: Float = 0.0001

    struct Segment {
        var a: Point
        var b: Point
        var horizontal: Bool { abs(a.y - b.y) < epsilon }
        var length: Float { abs(a.x - b.x) + abs(a.y - b.y) }
    }

    struct Score {
        var missing = 0
        var overlaps = 0
        var crossings = 0
        var shared = 0
        var proximity = 0
        var bends = 0
        var length: Float = 0.0
        var area: Float = 0.0

        /// Proximity ranks after sharing and, with crossings, ahead of bends. A proximate pair is
        /// weighed as `proximityWeight` crossings: a strict order would give up hundreds of
        /// crossings to remove one residual near-parallel pair in a dense component.
        static let proximityWeight = 4

        func precedes(_ b: Score) -> Bool {
            let aValues = [
                Float(missing + overlaps), Float(shared), Float(crossings + Self.proximityWeight * proximity),
                Float(proximity), Float(bends), length, area,
            ]
            let bValues = [
                Float(b.missing + b.overlaps), Float(b.shared), Float(b.crossings + Self.proximityWeight * b.proximity),
                Float(b.proximity), Float(b.bends), b.length, b.area,
            ]
            for (a, b) in zip(aValues, bValues) where a != b { return a < b }
            return false
        }
    }

    static func segments(_ path: [Point]) -> [Segment] { zip(path, path.dropFirst()).map { Segment(a: $0, b: $1) } }

    static func shared(_ a: Segment, _ b: Segment) -> Bool {
        if a.horizontal != b.horizontal { return false }
        if a.horizontal {
            return abs(a.a.y - b.a.y) < epsilon
                && min(max(a.a.x, a.b.x), max(b.a.x, b.b.x)) - max(min(a.a.x, a.b.x), min(b.a.x, b.b.x)) > epsilon
        }
        return abs(a.a.x - b.a.x) < epsilon
            && min(max(a.a.y, a.b.y), max(b.a.y, b.b.y)) - max(min(a.a.y, a.b.y), min(b.a.y, b.b.y)) > epsilon
    }

    static func nearShared(_ a: Segment, _ b: Segment, spacing: Float, minimumLength: Float = 12) -> Bool {
        guard a.horizontal == b.horizontal else { return false }
        if a.horizontal {
            return abs(a.a.y - b.a.y) < spacing - epsilon
                && min(max(a.a.x, a.b.x), max(b.a.x, b.b.x)) - max(min(a.a.x, a.b.x), min(b.a.x, b.b.x)) > minimumLength
        }
        return abs(a.a.x - b.a.x) < spacing - epsilon
            && min(max(a.a.y, a.b.y), max(b.a.y, b.b.y)) - max(min(a.a.y, a.b.y), min(b.a.y, b.b.y)) > minimumLength
    }

    static func crossing(_ a: Segment, _ b: Segment) -> Point? {
        guard a.horizontal != b.horizontal else { return nil }
        let h = a.horizontal ? a : b
        let v = a.horizontal ? b : a
        let p = Point(x: v.a.x, y: h.a.y)
        return p.x > min(h.a.x, h.b.x) + epsilon && p.x < max(h.a.x, h.b.x) - epsilon
            && p.y > min(v.a.y, v.b.y) + epsilon && p.y < max(v.a.y, v.b.y) - epsilon ? p : nil
    }

    /// Crossing points, exactly shared pairs and near-parallel pairs (closer than `spacing`
    /// with overlap beyond the minimum run) between different routes. A pair that shares
    /// exactly is not also counted as proximate. The grid visits only neighbouring segments.
    static func pairStatistics(
        _ lines: [[Segment]],
        spacing: Float
    ) throws -> (crossings: Int, shared: Int, proximity: Int) {
        let grid = DirectedSegmentGrid()
        for (i, line) in lines.enumerated() { for s in line { grid.insert(s, owner: i) } }
        var crossings = 0
        var sharedPairs = 0
        var proximity = 0
        for i in lines.indices {
            try Task.checkCancellation()
            var hits: [Int: Set<Point>] = [:]
            var sharing: Set<Int> = []
            var near: Set<Int> = []
            for a in lines[i] {
                grid.forEach(near: a, margin: spacing) { j, b in
                    guard j > i else { return }
                    if let p = crossing(a, b) { hits[j, default: []].insert(p) }
                    if shared(a, b) { sharing.insert(j) } else if nearShared(a, b, spacing: spacing) { near.insert(j) }
                }
            }
            crossings += hits.values.reduce(0) { $0 + $1.count }
            sharedPairs += sharing.count
            proximity += near.subtracting(sharing).count
        }
        return (crossings, sharedPairs, proximity)
    }

    static func proximity(edges: [LayoutEdge], spacing: Float) throws -> Int {
        try pairStatistics(edges.map { segments($0.path) }, spacing: spacing).proximity
    }

    static func measure(nodes: [LayoutNode], edges: [LayoutEdge], spacing: Float = 10) throws -> Score {
        var score = Score()
        let lines = edges.map { segments($0.path) }
        for i in nodes.indices {
            for j in nodes.indices where j > i && nodes[i].bounds.intersects(nodes[j].bounds) { score.overlaps += 1 }
        }
        for i in edges.indices {
            if edges[i].path.count < 2 { score.missing += 1 }
            score.bends += max(0, edges[i].path.count - 2)
            score.length += lines[i].reduce(0) { $0 + $1.length }
        }
        let pairs = try pairStatistics(lines, spacing: spacing)
        score.crossings = pairs.crossings
        score.shared = pairs.shared
        score.proximity = pairs.proximity
        let rect = bounds(nodes: nodes, edges: edges)
        score.area = rect.width * rect.height
        return score
    }

    static func bounds(nodes: [LayoutNode], edges: [LayoutEdge]) -> Rect {
        let points =
            nodes.flatMap {
                [Point(x: $0.bounds.left, y: $0.bounds.top), Point(x: $0.bounds.right, y: $0.bounds.bottom)]
            } + edges.flatMap(\.path)
        guard let first = points.first else { return Rect() }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for p in points {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func compact(_ path: [Point]) -> [Point] {
        var result: [Point] = []
        for p in path {
            if result.last == p { continue }
            if result.count >= 2 {
                let a = result[result.count - 2]
                // Inside `result.count >= 2`.
                let b = result.last!
                let u = b - a
                let v = p - b
                if abs(u.x * v.y - u.y * v.x) < epsilon && u.x * v.x + u.y * v.y >= 0 { result.removeLast() }
            }
            result.append(p)
        }
        return result
    }

    static func clear(_ a: Point, _ b: Point, bodies: [Rect]) -> Bool {
        if abs(a.x - b.x) > epsilon && abs(a.y - b.y) > epsilon { return false }
        return !bodies.contains { r in
            if abs(a.x - b.x) < epsilon {
                return a.x > r.left + epsilon && a.x < r.right - epsilon
                    && max(a.y, b.y) > r.top + epsilon && min(a.y, b.y) < r.bottom - epsilon
            }
            return a.y > r.top + epsilon && a.y < r.bottom - epsilon
                && max(a.x, b.x) > r.left + epsilon && min(a.x, b.x) < r.right - epsilon
        }
    }
}
