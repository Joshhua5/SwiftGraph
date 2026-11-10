import Foundation

/// Quantize equality and hashing identically: tolerance-only equality severs segment chains.
struct BspPointKey: Hashable {
    var x: Int64
    var y: Int64

    init(_ p: Point) {
        x = Int64(floor(Double(p.x) / 1e-4 + 0.5))
        y = Int64(floor(Double(p.y) / 1e-4 + 0.5))
    }
}

struct BspVisibilityGraph {
    private var points: [Point] = []
    private var indices: [BspPointKey: Int] = [:]
    private var adjacency: [[Int]] = []
    private let segments: [(start: Point, end: Point)]

    init(_ segments: [(start: Point, end: Point)]) {
        self.segments = segments
        for s in segments {
            _ = insert(s.start)
            _ = insert(s.end)
        }
        if let candidates = RoutingCompute.current?.overlapPairs(segments) {
            for i in segments.indices {
                if RoutingCompute.isCancelled { return }
                for j in candidates[i] {
                    if let p = intersection(segments[i], segments[j]) { _ = insert(p) }
                }
            }
        } else {
            for i in segments.indices {
                if RoutingCompute.isCancelled { return }
                for j in (i + 1)..<segments.count {
                    if let p = intersection(segments[i], segments[j]) { _ = insert(p) }
                }
            }
        }
        for s in segments {
            if RoutingCompute.isCancelled { return }
            let vertical = abs(s.start.x - s.end.x) < 0.001
            let on = points.indices.filter { onSegment(s, points[$0]) }
                .sorted { vertical ? points[$0].y < points[$1].y : points[$0].x < points[$1].x }
            for (a, b) in zip(on, on.dropFirst()) { link(a, b) }
        }
    }

    @discardableResult private mutating func insert(_ p: Point) -> Int {
        let key = BspPointKey(p)
        if let i = indices[key] { return i }
        let i = points.count
        points.append(p)
        adjacency.append([])
        indices[key] = i
        return i
    }

    private mutating func link(_ a: Int, _ b: Int) {
        adjacency[a].append(b)
        adjacency[b].append(a)
    }

    /// Joins a side port to its hit point, splicing the hit into every segment it lies on.
    mutating func attach(_ port: Point, to hit: Point) {
        let existing = indices[BspPointKey(hit)] != nil
        let h = insert(hit)
        if !existing {
            for s in segments where onSegment(s, hit) {
                let vertical = abs(s.start.x - s.end.x) < 0.001
                let along = { (p: Point) in vertical ? p.y : p.x }
                let on = points.indices.filter { $0 != h && onSegment(s, points[$0]) }
                if let before = on.filter({ along(points[$0]) < along(hit) })
                    .max(by: { along(points[$0]) < along(points[$1]) })
                {
                    link(h, before)
                }
                if let after = on.filter({ along(points[$0]) > along(hit) })
                    .min(by: { along(points[$0]) < along(points[$1]) })
                {
                    link(h, after)
                }
            }
        }
        if BspPointKey(port) != BspPointKey(hit) { link(insert(port), h) }
    }

    func path(from starts: [Point], to ends: [Point], bendPenalty: Float) -> [Point]? {
        path(from: starts.map { ($0, 0) }, to: ends.map { ($0, 0) }, bendPenalty: bendPenalty)
    }

    /// A* over (vertex, axis) states from any start to any end, charging `bendPenalty` per change of axis and each
    /// port's own cost for starting or finishing there.
    /// `blocked` replaces `obstacles` when the caller already indexes them: it reports whether a link is cut.
    func path(
        from starts: [(Point, Float)],
        to ends: [(Point, Float)],
        bendPenalty: Float,
        obstacles: [Rect] = [],
        blocked: ((Point, Point) -> Bool)? = nil
    ) -> [Point]? {
        let cuts: (Point, Point) -> Bool
        if let blocked {
            cuts = blocked
        } else {
            let obstacleBounds =
                obstacles.first.map { first in obstacles.dropFirst().reduce(first) { $0.union($1) } } ?? Rect()
            let tree = QuadTree<Rect>(bounds: obstacleBounds.inflated(by: 1))
            for r in obstacles where r.width > 0 && r.height > 0 { tree.insert(bounds: r, item: r) }
            cuts = { a, b in
                tree.contains(intersecting: RoutingCompute.bounds(a, b).inflated(by: 1e-4)) { r, _ in
                    r.intersectsLine(a, b)
                }
            }
        }
        var goals: [Int: Float] = [:]
        for (p, c) in ends { if let i = indices[BspPointKey(p)], c < goals[i, default: .infinity] { goals[i] = c } }
        let targets = ends.map(\.0)
        func estimate(_ p: Point) -> Float {
            var best = Float.infinity
            for t in targets { best = min(best, abs(t.x - p.x) + abs(t.y - p.y)) }
            return targets.isEmpty ? 0 : best
        }
        var queue = RoutingPriorityQueue<Int>()
        var costs: [Int: Float] = [:]
        var previous: [Int: Int] = [:]
        for (start, cost) in starts {
            guard let a = indices[BspPointKey(start)], cost < costs[a * 3, default: .infinity] else { continue }
            costs[a * 3] = cost
            queue.push(a * 3, priority: cost + estimate(start))
        }
        var settled = Set<Int>()
        while let state = queue.pop() {
            if RoutingCompute.isCancelled { return nil }
            guard settled.insert(state).inserted else { continue }
            let vertex = state / 3
            let axis = state % 3
            if goals[vertex] != nil {
                var path = [points[vertex]]
                var cursor = state
                while let p = previous[cursor] {
                    path.append(points[p / 3])
                    cursor = p
                }
                return path.reversed()
            }
            for next in adjacency[vertex] {
                let a = points[vertex]
                let b = points[next]
                if cuts(a, b) { continue }
                let d = points[next] - points[vertex]
                let nextAxis = abs(d.x) >= abs(d.y) ? 1 : 2
                let cost =
                    costs[required: state] + abs(d.x) + abs(d.y) + (axis != 0 && axis != nextAxis ? bendPenalty : 0)
                    + (goals[next] ?? 0)
                let key = next * 3 + nextAxis
                if cost < costs[key, default: .infinity] {
                    costs[key] = cost
                    previous[key] = state
                    queue.push(key, priority: cost + estimate(points[next]))
                }
            }
        }
        return nil
    }

    private func onSegment(_ s: (start: Point, end: Point), _ p: Point) -> Bool {
        abs((s.start - p).length + (p - s.end).length - (s.start - s.end).length) < 0.001
    }

    private func intersection(_ a: (start: Point, end: Point), _ b: (start: Point, end: Point)) -> Point? {
        let da = a.end - a.start
        let db = b.end - b.start
        let denominator = db.y * da.x - db.x * da.y
        if denominator == 0 { return nil }
        let delta = a.start - b.start
        let u = (db.x * delta.y - db.y * delta.x) / denominator
        let v = (da.x * delta.y - da.y * delta.x) / denominator
        return u >= 0 && u <= 1 && v >= 0 && v <= 1 ? a.start + da * u : nil
    }
}
