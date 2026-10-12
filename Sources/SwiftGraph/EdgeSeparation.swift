import Foundation

/// Spreads edges that run along the same collinear stretch into parallel lanes `spacing` apart, so duplicate,
/// reciprocal and corridor-sharing edges stay individually traceable. Lanes are ordered by the side each edge
/// arrives from and leaves towards, so they do not cross where they split. Each segment moves along its own
/// normal and bends are re-intersected, so orthogonal routes stay orthogonal. An edge whose separated path
/// would newly cut a node keeps its original route. Self-loops are untouched.
public final class EdgeSeparator: EdgeRouter {
    public var spacing: Double = 6
    public init() {}

    private struct Segment {
        var edge: Int, index: Int
        var start: Point, end: Point, direction: Point, normal: Point
        var low: Double, high: Double
        /// Whether the low/high end is an interior bend, which moves along the line when its neighbour shifts.
        var lowBends: Bool, highBends: Bool
    }
    private static let tolerance = 1e-6

    public func routeEdges(_ graph: LayoutGraph) {
        guard spacing > 0, spacing.isFinite else { return }
        let edges = graph.edges.filter { $0.source !== $0.target }
        let bodies = graph.nodes.filter { !$0.isGroup }.map(\.bounds)
        let paths = edges.map { Self.simplified($0.path) }
        var segments: [Segment] = []
        for (e, path) in paths.enumerated() where path.count >= 2 {
            for k in path.indices.dropLast() {
                let a = path[k], b = path[k + 1], delta = b - a
                var u = delta / delta.length
                // One canonical direction per line, so reciprocal edges land on the same track.
                if u.x < -1e-9 || (abs(u.x) <= 1e-9 && u.y < 0) { u = u * -1 }
                let ta = Self.dot(u, a), tb = Self.dot(u, b)
                let startBends = k > 0, endBends = k + 2 < path.count
                segments.append(Segment(edge: e, index: k, start: a, end: b, direction: u, normal: Point(x: -u.y, y: u.x),
                                        low: min(ta, tb), high: max(ta, tb),
                                        lowBends: ta <= tb ? startBends : endBends, highBends: ta <= tb ? endBends : startBends))
            }
        }
        if RoutingCompute.isCancelled { return }
        // Collinear runs that nearly meet at a bend count as shared: once that bend moves to its lane,
        // the runs would otherwise be pushed into each other. Runs meeting only at path ends stay apart.
        let reach = 2 * spacing
        let groups = Self.sharedGroups(segments, reach: reach)
        var shifts = paths.map { Array(repeating: Point.zero, count: max(0, $0.count - 1)) }
        for group in groups {
            if RoutingCompute.isCancelled { return }
            let u = segments[group[0]].direction, n = segments[group[0]].normal
            var spans: [Int: (low: Double, high: Double, first: Int)] = [:]
            for s in group {
                let segment = segments[s]
                if let span = spans[segment.edge] {
                    spans[segment.edge] = (min(span.low, segment.low), max(span.high, segment.high), min(span.first, segment.index))
                } else {
                    spans[segment.edge] = (segment.low, segment.high, segment.index)
                }
            }
            guard spans.count > 1 else { continue }
            // Insertion sort: the pairwise order need not be transitive when some crossing is unavoidable.
            var ordered: [Int] = []
            for e in spans.keys.sorted() {
                let position = ordered.firstIndex { Self.precedes(e, $0, paths, spans[e]!.first, spans[$0]!.first, u) } ?? ordered.count
                ordered.insert(e, at: position)
            }
            // Interval colouring: edges whose runs stay `reach` apart share a lane, keeping the spread narrow.
            var lanes: [[(Double, Double)]] = [], lane: [Int: Int] = [:]
            for e in ordered {
                let span = spans[e]!
                let free = lanes.firstIndex { taken in !taken.contains { Self.overlaps($0, (span.low, span.high), reach: reach) } }
                if let free { lanes[free].append((span.low, span.high)); lane[e] = free } else { lanes.append([(span.low, span.high)]); lane[e] = lanes.count - 1 }
            }
            guard lanes.count > 1 else { continue }
            // Narrow corridors get tighter lanes rather than none; a corridor too narrow for 1pt lanes stays merged.
            let step = min(spacing, Self.room(group.map { segments[$0] }, bodies) / (Double(lanes.count - 1) / 2))
            guard step >= 1 else { continue }
            for s in group {
                let offset = (Double(lane[segments[s].edge]!) - Double(lanes.count - 1) / 2) * step
                shifts[segments[s].edge][segments[s].index] = n * offset
            }
        }
        if RoutingCompute.isCancelled { return }
        for (e, edge) in edges.enumerated() where shifts[e].contains(where: { $0 != .zero }) {
            var path = Self.shifted(paths[e], shifts[e])
            path[0] = Self.keep(path[0], original: paths[e][0], inside: edge.source.bounds)
            path[path.count - 1] = Self.keep(path[path.count - 1], original: paths[e][paths[e].count - 1], inside: edge.target.bounds)
            let obstacles = ObstaclePolyline.obstacles(edge, graph).map { $0.inflated(by: -Self.tolerance) }.filter { $0.width > 0 && $0.height > 0 }
            let before = Self.hits(edge.path, obstacles)
            if Self.hits(path, obstacles).isSubset(of: before) { edge.path = path }
        }
    }

    /// Removes repeated points and straight-through interior points so each segment is a maximal straight run.
    private static func simplified(_ path: [Point]) -> [Point] {
        var result: [Point] = []
        for p in path {
            if let last = result.last, (p - last).length <= tolerance { continue }
            if result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1], u = b - a, v = p - b
                if abs(cross(u, v)) <= tolerance * u.length * v.length && dot(u, v) > 0 { result[result.count - 1] = p; continue }
            }
            result.append(p)
        }
        return result
    }

    /// Unions collinear segments (within the shared-segment measure's tolerance) that overlap, or come within
    /// `reach` of each other at a bend.
    private static func sharedGroups(_ segments: [Segment], reach: Double) -> [[Int]] {
        struct Key: Hashable { var angle: Int; var offset: Int }
        func key(_ s: Segment) -> Key {
            Key(angle: Int((atan2(s.direction.y, s.direction.x) / 1e-4).rounded()), offset: Int((dot(s.normal, s.start) / 1).rounded()))
        }
        var buckets: [Key: [Int]] = [:]
        for (i, s) in segments.enumerated() { buckets[key(s), default: []].append(i) }
        let candidates = RoutingCompute.current?.overlapMatrix(segments.map { (start: $0.start, end: $0.end) }, padding: reach + tolerance)
        var parent = Array(segments.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for (i, s) in segments.enumerated() {
            let k = key(s)
            for da in -1...1 { for dc in -1...1 {
                for j in buckets[Key(angle: k.angle + da, offset: k.offset + dc)] ?? [] where j > i && segments[j].edge != s.edge {
                    if let candidates, candidates[i * segments.count + j] == 0 { continue }
                    let t = segments[j], length = (s.end - s.start).length
                    guard abs(cross(s.end - s.start, t.start - s.start)) / length < tolerance,
                          abs(cross(s.end - s.start, t.end - s.start)) / length < tolerance,
                          min(s.high, t.high) - max(s.low, t.low) > -reach else { continue }
                    let overlap = min(s.high, t.high) - max(s.low, t.low)
                    let facingBend = s.high <= t.low ? s.highBends || t.lowBends : t.highBends || s.lowBends
                    guard overlap > tolerance || facingBend else { continue }
                    parent[root(j)] = root(i)
                }
            } }
        }
        var groups: [Int: [Int]] = [:]
        for i in segments.indices { groups[root(i), default: []].append(i) }
        return groups.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
    }

    /// Whether edge `a` belongs on the `-n` side of edge `b`. Both trails are followed past the shared stretch
    /// until they part, so consecutive shared stretches agree on the order; the leaving end decides, then the
    /// arriving end, then edge order.
    private static func precedes(_ a: Int, _ b: Int, _ paths: [[Point]], _ ka: Int, _ kb: Int, _ u: Point) -> Bool {
        for ahead in [true, false] {
            let turn = parting(trail(paths[a], ka, u, ahead), trail(paths[b], kb, u, ahead), ahead ? u : u * -1)
            if abs(turn) > 1e-9 { return ahead ? turn < 0 : turn > 0 }
        }
        // Paths that never part: the lower-index edge keeps to the left of its own travel, which stays
        // consistent round corners, unlike a fixed side of each track.
        let (r, k) = a < b ? (a, ka) : (b, kb)
        let forward = dot(paths[r][k + 1] - paths[r][k], u) > 0
        return r == a ? !forward : forward
    }

    /// Free half-width beside a shared stretch, less a 2pt gap: the nearer node on either side bounds it.
    private static func room(_ group: [Segment], _ bodies: [Rect]) -> Double {
        let u = group[0].direction, n = group[0].normal, c = dot(n, group[0].start)
        let low = group.map(\.low).min()!, high = group.map(\.high).max()!
        var minus = Double.infinity, plus = Double.infinity
        for r in bodies {
            let corners = [Point(x: r.left, y: r.top), Point(x: r.right, y: r.top), Point(x: r.left, y: r.bottom), Point(x: r.right, y: r.bottom)]
            let along = corners.map { dot(u, $0) }, across = corners.map { dot(n, $0) }
            guard min(high, along.max()!) - max(low, along.min()!) > tolerance else { continue }
            if across.max()! <= c + tolerance { minus = min(minus, c - across.max()!) }
            else if across.min()! >= c - tolerance { plus = min(plus, across.min()! - c) }
        }
        return min(minus, plus) - 2
    }

    /// The path beyond a shared segment, starting at its end in the canonical direction (`ahead`) or its start.
    private static func trail(_ path: [Point], _ k: Int, _ u: Point, _ ahead: Bool) -> [Point] {
        (dot(path[k + 1] - path[k], u) > 0) == ahead ? Array(path[(k + 1)...]) : Array(path[...k].reversed())
    }

    /// Signed angle by which trail `a` parts counter-clockwise of trail `b`, both travelling along `direction`.
    private static func parting(_ a: [Point], _ b: [Point], _ direction: Point) -> Double {
        func angle(_ d: Point, _ v: Point) -> Double { v.length <= tolerance ? 0 : atan2(cross(d, v), dot(d, v)) }
        // Ends at different points on the shared line: the nearer one turns first while the other runs on.
        if (a[0] - b[0]).length > tolerance {
            let aFirst = dot(direction, a[0]) < dot(direction, b[0])
            let turner = aFirst ? a : b, turn = turner.count > 1 ? angle(direction, turner[1] - turner[0]) : 0
            return aFirst ? turn : -turn
        }
        var c = a[0], d = direction, i = 1
        while i < a.count && i < b.count && (a[i] - b[i]).length <= tolerance {
            if (a[i] - c).length > tolerance { d = (a[i] - c) / (a[i] - c).length }
            c = a[i]; i += 1
        }
        return angle(d, i < a.count ? a[i] - c : d) - angle(d, i < b.count ? b[i] - c : d)
    }

    /// Moves each segment by its shift and re-intersects neighbouring segments. A U-turn gets a perpendicular
    /// connector, which keeps orthogonal routes orthogonal; a shallow bend whose mitre would overshoot takes
    /// the averaged shift instead of a visible notch.
    private static func shifted(_ path: [Point], _ shifts: [Point]) -> [Point] {
        var result = [path[0] + shifts[0]]
        for k in path.indices.dropFirst().dropLast() {
            let d1 = shifts[k - 1], d2 = shifts[k]
            if d1 == d2 { result.append(path[k] + d1); continue }
            let p1 = path[k - 1] + d1, v1 = path[k] - path[k - 1], p2 = path[k] + d2, v2 = path[k + 1] - path[k]
            let denominator = cross(v1, v2), limit = 4 * max(d1.length, d2.length)
            if abs(denominator) > 1e-12 * v1.length * v2.length {
                let corner = p1 + v1 * (cross(p2 - p1, v2) / denominator)
                if (corner - path[k]).length <= limit { result.append(corner); continue }
            }
            if dot(v1, v2) < 0 { result += [path[k] + d1, path[k] + d2] } else { result.append(path[k] + (d1 + d2) / 2) }
        }
        result.append(path[path.count - 1] + shifts[shifts.count - 1])
        return result
    }

    /// An endpoint that started on or inside its node stays there after shifting.
    private static func keep(_ point: Point, original: Point, inside bounds: Rect) -> Point {
        guard bounds.contains(original), !bounds.contains(point) else { return point }
        return Point(x: min(max(point.x, bounds.left), bounds.right), y: min(max(point.y, bounds.top), bounds.bottom))
    }

    private static func hits(_ path: [Point], _ obstacles: [Rect]) -> Set<Int> {
        if let compute = RoutingCompute.current { return compute.hits(path, obstacles) }
        return Set(obstacles.indices.filter { i in zip(path, path.dropFirst()).contains { obstacles[i].intersectsLine($0, $1) } })
    }
    private static func overlaps(_ a: (Double, Double), _ b: (Double, Double), reach: Double) -> Bool {
        min(a.1, b.1) - max(a.0, b.0) > -reach
    }
    private static func dot(_ a: Point, _ b: Point) -> Double { a.x * b.x + a.y * b.y }
    private static func cross(_ a: Point, _ b: Point) -> Double { a.x * b.y - a.y * b.x }
}
