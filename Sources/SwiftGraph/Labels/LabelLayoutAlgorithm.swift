import Foundation

public final class LabelLayoutAlgorithm {
    public var iterations = 200

    /// Edges without a label (no text and no size on `labelBounds`) are left alone.
    public var labelProvider: (LayoutEdge) -> String? = defaultLabelProvider
    public var sizeProvider: (LayoutEdge, String) -> Size? = { _, _ in nil }

    public init() {}

    public func applyLabelLayout(_ graph: LayoutGraph) {
        let edges = graph.edges.filter { edge in
            !(labelProvider(edge) ?? "").isEmpty || (edge.labelBounds.width > 0 && edge.labelBounds.height > 0)
        }
        guard !edges.isEmpty else { return }
        let obstacles = graph.nodes.filter { !$0.isGroup }.map(\.bounds)
        for e in edges {
            let size = labelSize(e, text: labelProvider(e), provider: sizeProvider)
            e.labelBounds = Rect(x: e.labelBounds.x, y: e.labelBounds.y, width: size.width, height: size.height)
            if e.path.count >= 2 {
                let center = LabelCollisionRepair.midpoint(e.path)
                e.labelBounds.x = center.x - e.labelBounds.width / 2
                e.labelBounds.y = center.y - e.labelBounds.height / 2
            }
        }
        let segments = SegmentIndex(graph.edges)
        let compute = RoutingCompute.current
        /// One label's share of the energy: nodes it covers, other labels it overlaps, edges crossing it, and its
        /// distance
        /// from its own edge. An overlap costs 100 per label involved, so moving a label changes it by `overlap` = 200.
        func energy(
            of e: LayoutEdge,
            rect: Rect,
            others: [Rect],
            flags: [UInt32]?,
            flagOffset: Int,
            overlap: Float
        ) -> Float {
            var result =
                Float(
                    obstacles.indices.filter { (flags?[flagOffset + $0] ?? 1) != 0 && obstacles[$0].intersects(rect) }
                        .count
                ) * 1000
            result +=
                Float(
                    others.indices
                        .filter { (flags?[flagOffset + obstacles.count + $0] ?? 1) != 0 && rect.intersects(others[$0]) }
                        .count
                ) * overlap
            result += Float(segments.hits(rect, except: e)) * 10
            if e.path.count >= 2 { result += LabelCollisionRepair.distance(rect.center, to: e.path) * 0.1 }
            return result
        }
        var random = SeededRandom(state: 123)
        var temperature: Float = 100.0
        _ = compute?.candidates(edges.map(\.labelBounds), obstacles + edges.map(\.labelBounds))
        var current = edges.indices.reduce(Float(0)) { i, idx in
            let others = edges.indices.filter { $0 != idx }.map { edges[$0].labelBounds }
            return i
                + energy(
                    of: edges[idx],
                    rect: edges[idx].labelBounds,
                    others: others,
                    flags: nil,
                    flagOffset: 0,
                    overlap: 100
                )
        }
        var best = current
        var bestBounds = edges.map(\.labelBounds)
        // A step compares two rectangles against every target: far below the round-trip threshold, and a flag
        // would only skip an `intersects` test that costs as much, so annealing stays on the exact CPU path.
        for _ in 0..<max(0, iterations) {
            if RoutingCompute.isCancelled { return }
            let moved = Int(random.next() * Double(edges.count))
            let edge = edges[moved]
            let old = edge.labelBounds
            let others = edges.indices.filter { $0 != moved }.map { edges[$0].labelBounds }
            edge.labelBounds.x += (Float(random.next()) - 0.5) * temperature
            edge.labelBounds.y += (Float(random.next()) - 0.5) * temperature
            let proposed = edge.labelBounds
            let before = energy(of: edge, rect: old, others: others, flags: nil, flagOffset: 0, overlap: 200)
            let after = energy(of: edge, rect: proposed, others: others, flags: nil, flagOffset: 0, overlap: 200)
            let candidate = current - before + after
            if candidate < current || Float(random.next()) <= exp((current - candidate) / max(temperature, 1e-6)) {
                current = candidate
            } else {
                edge.labelBounds = old
            }
            if current < best {
                best = current
                bestBounds = edges.map(\.labelBounds)
            }
            temperature *= 0.95
        }
        for (edge, bounds) in zip(edges, bestBounds) { edge.labelBounds = bounds }
        LabelCollisionRepair.apply(edges, among: graph.edges, obstacles: obstacles)
    }
}

/// Path segments indexed by bounding box, so a label can count the other edges running through it.
private struct SegmentIndex {
    let tree: QuadTree<Int>
    let segments: [(edge: LayoutEdge, a: Point, b: Point)]

    init(_ edges: [LayoutEdge]) {
        segments = edges.flatMap { e in zip(e.path, e.path.dropFirst()).map { (edge: e, a: $0, b: $1) } }
        let boxes = segments.map { RoutingCompute.bounds($0.a, $0.b).inflated(by: 0.5) }
        tree = QuadTree<Int>(bounds: boxes.dropFirst().reduce(boxes.first ?? Rect()) { $0.union($1) }.inflated(by: 1))
        for (i, box) in boxes.enumerated() { tree.insert(bounds: box, item: i) }
    }

    func hits(_ rect: Rect, except edge: LayoutEdge) -> Int {
        var seen = Set<ObjectIdentifier>()
        for i in tree.query(rect.inflated(by: 0.5))
        where segments[i].edge !== edge && rect.intersectsLine(segments[i].a, segments[i].b) {
            seen.insert(ObjectIdentifier(segments[i].edge))
        }
        return seen.count
    }
}

enum LabelCollisionRepair {
    static func midpoint(_ path: [Point]) -> Point {
        let segments = Array(zip(path, path.dropFirst()))
        var remaining = segments.reduce(Float(0)) { $0 + ($1.1 - $1.0).length } / 2
        for (a, b) in segments {
            let length = (b - a).length
            if length > 0 && remaining <= length { return a + (b - a) * (remaining / length) }
            remaining -= length
        }
        return path.first ?? .zero
    }

    static func distance(_ point: Point, to path: [Point]) -> Float {
        zip(path, path.dropFirst())
            .map { a, b in
                let delta = b - a
                let t =
                    delta.lengthSquared > 0
                    ? max(0, min(1, ((point.x - a.x) * delta.x + (point.y - a.y) * delta.y) / delta.lengthSquared)) : 0
                return (point - (a + delta * t)).length
            }
            .min() ?? path.first.map { (point - $0).length } ?? 0
    }

    /// Moves each label to the candidate along its own edge that covers the fewest nodes, other labels and other edges.
    static func apply(_ edges: [LayoutEdge], among all: [LayoutEdge], obstacles: [Rect]) {
        let segments = SegmentIndex(all)
        var dispatched = false
        for _ in 0..<8 {
            var changed = false
            for (index, edge) in edges.enumerated() where edge.labelBounds.width > 0 && edge.labelBounds.height > 0 {
                if RoutingCompute.isCancelled { return }
                let original = edge.labelBounds
                let labelRects = edges.map(\.labelBounds)
                if dispatched && !obstacles.contains(where: { $0.intersects(original) })
                    && !edges.indices.contains(where: { $0 != index && labelRects[$0].intersects(original) })
                    && segments.hits(original, except: edge) == 0
                {
                    continue
                }
                var candidates = [original]
                for (a, b) in zip(edge.path, edge.path.dropFirst()) {
                    let delta = b - a
                    guard delta.length > 1e-6 else { continue }
                    let normal = Point(x: -delta.y, y: delta.x) / delta.length
                    let clearance = abs(normal.x) * original.width / 2 + abs(normal.y) * original.height / 2 + 4
                    for t: Float in [0.5, 0.25, 0.75] {
                        for offset: Float in [0.0, 1, -1, 2, -2, 3, -3] {
                            let center = a + delta * t + normal * (offset * clearance)
                            candidates.append(
                                Rect(
                                    x: center.x - original.width / 2,
                                    y: center.y - original.height / 2,
                                    width: original.width,
                                    height: original.height
                                )
                            )
                        }
                    }
                }
                let combinedTargets = obstacles + labelRects
                let combinedFlags = RoutingCompute.current?.candidates(candidates, combinedTargets)
                dispatched = true
                let stride = combinedTargets.count
                func score(_ i: Int) -> [Float] {
                    let rect = candidates[i]
                    let base = i * stride
                    return [
                        Float(
                            obstacles.indices
                                .filter { j in (combinedFlags?[base + j] ?? 1) != 0 && obstacles[j].intersects(rect) }
                                .count
                        ),
                        Float(
                            edges.indices
                                .filter { j in
                                    j != index && (combinedFlags?[base + obstacles.count + j] ?? 1) != 0
                                        && labelRects[j].intersects(rect)
                                }
                                .count
                        ),
                        Float(segments.hits(rect, except: edge)),
                        distance(rect.center, to: edge.path), (rect.center - original.center).lengthSquared,
                    ]
                }
                var best = original
                var bestScore = score(0)
                if bestScore[0] == 0 && bestScore[1] == 0 && bestScore[2] == 0 { continue }
                for i in candidates.indices.dropFirst() {
                    let candidate = score(i)
                    if candidate.lexicographicallyPrecedes(bestScore) {
                        best = candidates[i]
                        bestScore = candidate
                    }
                }
                if best != original {
                    edge.labelBounds = best
                    changed = true
                }
            }
            if !changed { break }
        }
    }
}
