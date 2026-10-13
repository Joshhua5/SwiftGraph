import Foundation

/// Spreads edges that run along the same stretch (collinear, or within a couple of degrees and `spacing` of each
/// other) into parallel lanes `spacing` apart, so duplicate, reciprocal and corridor-sharing edges stay individually
/// traceable. Lanes are ordered by the side each edge arrives from and leaves towards, and an edge never takes a lane
/// below one it must follow, so they do not cross where they split. Each segment moves along the group normal and
/// bends are re-intersected, so orthogonal routes stay orthogonal. A shift that would newly cut a node, cross the
/// edge itself, turn it back on itself or cross an edge joining the same two nodes is dropped on its own, leaving
/// the edge's other shifts in place. A lane that leaves a node square to a face stays on that face, clear of its
/// corners: the lanes slide along the line to fit it, and draw closer together if it is still too small, so
/// orthogonal routes never end in a diagonal stub. Self-loops are untouched.
public final class EdgeSeparator: EdgeRouter {
    public var spacing: Double = 10
    /// Edges still sharing a stretch after the last run: the corridor had no room for lanes, or the lanes would cut a node.
    public private(set) var unseparatedEdges: [LayoutEdge] = []
    /// The most lanes any one shared stretch was spread over in the last run.
    private(set) var widestGroup = 0
    public init() {}

    private struct Segment {
        var edge: Int, index: Int
        var start: Point, end: Point, direction: Point, normal: Point
        var low: Double, high: Double
        /// Whether the low/high end is an interior bend, which moves along the line when its neighbour shifts.
        var lowBends: Bool, highBends: Bool
    }
    private static let tolerance = 1e-6
    /// Segments this close in direction count as running the same way.
    private static let angleLimit = sin(2 * Double.pi / 180)

    public func routeEdges(_ graph: LayoutGraph) { separate(graph.edges, ObstaclePolyline.Scene(graph.nodes)) }

    func separate(_ all: [LayoutEdge], _ scene: ObstaclePolyline.Scene) {
        unseparatedEdges = []; widestGroup = 0
        guard spacing > 0, spacing.isFinite else { return }
        let edges = all.filter { $0.source !== $0.target }
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
        // Runs that nearly meet at a bend count as shared: once that bend moves to its lane,
        // the runs would otherwise be pushed into each other. Runs meeting only at path ends stay apart.
        let reach = 2 * spacing
        let groups = Self.sharedGroups(segments, reach: reach, spacing: spacing)
        var shifts = paths.map { Array(repeating: Point.zero, count: max(0, $0.count - 1)) }
        var shiftGroup = paths.map { Array(repeating: -1, count: max(0, $0.count - 1)) }
        var cramped = Set<Int>()
        for (g, group) in groups.enumerated() {
            if RoutingCompute.isCancelled { return }
            let u = segments[group[0]].direction, n = segments[group[0]].normal
            var spans: [Int: (low: Double, high: Double, first: Int)] = [:], runs: [Int: [(Double, Double)]] = [:]
            var perpendicular = 0.0
            for s in group {
                let segment = segments[s], ta = Self.dot(u, segment.start), tb = Self.dot(u, segment.end)
                perpendicular += Self.dot(n, segment.start + segment.end) / 2
                runs[segment.edge, default: []].append((min(ta, tb), max(ta, tb)))
                if let span = spans[segment.edge] {
                    spans[segment.edge] = (min(span.low, ta, tb), max(span.high, ta, tb), min(span.first, segment.index))
                } else {
                    spans[segment.edge] = (min(ta, tb), max(ta, tb), segment.index)
                }
            }
            guard spans.count > 1 else { continue }
            let centre = perpendicular / Double(group.count)
            // Insertion sort: the pairwise order need not be transitive when some crossing is unavoidable.
            var ordered: [Int] = []
            for e in spans.keys.sorted() {
                let position = ordered.firstIndex { Self.precedes(e, $0, paths, spans[e]!.first, spans[$0]!.first, u) } ?? ordered.count
                ordered.insert(e, at: position)
            }
            // Monotone lanes: an edge sits one lane beyond every earlier edge with a run within `reach` of one of its
            // own, so lanes keep the crossing-free order; edges whose runs are well apart along the line share a lane.
            var lane: [Int: Int] = [:], count = 1
            for (i, e) in ordered.enumerated() {
                let l = ordered[..<i].filter { f in runs[f]!.contains { a in runs[e]!.contains { Self.overlaps(a, $0, reach: reach) } } }.map { lane[$0]! + 1 }.max() ?? 0
                lane[e] = l; count = max(count, l + 1)
            }
            guard count > 1 else { continue }
            // Lanes sit `spacing` apart about the group. A node beside it pushes them to the open side, keeping a full
            // spacing from it if that still fits and half a spacing otherwise; a corridor too narrow for 1pt lanes stays merged.
            let low = spans.values.map(\.low).min()!, high = spans.values.map(\.high).max()!
            let room = Self.room(u, n, centre, low, high, scene, reach: Double(count + 1) * spacing)
            let span = Double(count - 1) * spacing
            // A lane that leaves a node square to its face must stay on the face, clear of its corners.
            let faces = group.compactMap { Self.faceSpan(segments[$0], paths, edges, n: n, spacing: spacing) }
            let faceLow = faces.map(\.low).max() ?? -.infinity, faceHigh = faces.map(\.high).min() ?? .infinity
            // The lanes' window is the corridor between the nearest nodes (less `reserve`) within the faces: centred on
            // the group and slid along it to fit, or drawn closer together when it is narrower than the full spread.
            func place(_ reserve: Double) -> (first: Double, step: Double) {
                let low = max(centre - max(room.minus - reserve, 0), faceLow), high = min(centre + max(room.plus - reserve, 0), faceHigh)
                guard high >= low else { return (centre, 0) }
                if high - low >= span - 1e-9 { return (min(max(centre - span / 2, low), high - span), spacing) }
                return (low, (high - low) / Double(count - 1))
            }
            var (first, step) = place(spacing)
            if step < spacing - 1e-9 { (first, step) = place(spacing / 2) }
            guard step >= 1 else { cramped.formUnion(spans.keys); continue }
            widestGroup = max(widestGroup, count)
            for s in group {
                let segment = segments[s], position = first + Double(lane[segment.edge]!) * step
                shifts[segment.edge][segment.index] = n * (position - Self.dot(n, segment.start + segment.end) / 2)
                shiftGroup[segment.edge][segment.index] = g
            }
        }
        if RoutingCompute.isCancelled { return }
        let originals = edges.map(\.path), twinGroups = Dictionary(grouping: edges.indices) { Self.pair(edges[$0]) }
        func build(_ e: Int, _ chosen: Set<Int>) -> [Point] {
            var path = Self.shifted(paths[e], zip(shifts[e], shiftGroup[e]).map { chosen.contains($1) ? $0 : .zero })
            Self.anchor(&path, paths[e], atStart: true, inside: edges[e].source.bounds, spacing: spacing)
            Self.anchor(&path, paths[e], atStart: false, inside: edges[e].target.bounds, spacing: spacing)
            return path
        }
        func moving(_ e: Int) -> [Int] { Set(zip(shifts[e], shiftGroup[e]).filter { $0.0 != .zero }.map(\.1)).sorted() }
        // Where every edge would sit with all its shifts: an edge is judged against the twins it will meet, not their old routes.
        let proposed = edges.indices.map { moving($0).isEmpty ? originals[$0] : build($0, Set(moving($0))) }
        for (e, edge) in edges.enumerated() where shifts[e].contains(where: { $0 != .zero }) {
            let moving = moving(e), all = proposed[e]
            let area = ObstaclePolyline.bounds(edge.path + all).inflated(by: 1)
            let obstacles = scene.near(area, edge).map { scene.rects[$0].inflated(by: -Self.tolerance) }.filter { $0.width > 0 && $0.height > 0 }
            let before = Self.hits(edge.path, obstacles)
            // A shift is kept only if it leaves the route no worse: no new node cut, self-crossing, U-turn,
            // or crossing with an edge joining the same two nodes.
            let twins = twinGroups[Self.pair(edge)]!.filter { $0 != e }.map { $0 < e ? edges[$0].path : proposed[$0] }
            let baseline = (Self.selfCrossings(edge.path), Self.reversals(edge.path), twins.map { Self.crossings(edge.path, $0) })
            func acceptable(_ path: [Point]) -> Bool {
                return Self.hits(path, obstacles).isSubset(of: before) && Self.selfCrossings(path) <= baseline.0 && Self.reversals(path) <= baseline.1
                    && zip(twins, baseline.2).allSatisfy { Self.crossings(path, $0) <= $1 }
            }
            if acceptable(all) { edge.path = all; continue }
            // Keep each group's shift that passes, and drop the rest.
            var chosen = Set<Int>()
            for g in moving where acceptable(build(e, chosen.union([g]))) { chosen.insert(g) }
            if !chosen.isEmpty { edge.path = build(e, chosen) }
            if chosen.count < moving.count { cramped.insert(e) }
        }
        // Touching points are not crossings, so an edge shifted against its twin's old route can still end up crossing
        // its twin's new one. Any pair that ends up crossing more than it started puts the later edge back.
        for list in twinGroups.values.filter({ $0.count > 1 }).sorted(by: { $0[0] < $1[0] }) {
            var changed = true
            while changed {
                changed = false
                for (a, i) in list.enumerated() { for j in list[(a + 1)...] where Self.crossings(edges[i].path, edges[j].path) > Self.crossings(originals[i], originals[j]) {
                    let back = edges[j].path != originals[j] ? j : i
                    edges[back].path = originals[back]; cramped.insert(back); changed = true
                } }
            }
        }
        unseparatedEdges = edges.indices.filter(cramped.contains).map { edges[$0] }
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

    /// Unions segments of different edges that run the same way (within `angleLimit`, and `spacing` apart across
    /// the stretch they share) and overlap, or come within `reach` of each other at a bend.
    private static func sharedGroups(_ segments: [Segment], reach: Double, spacing: Double) -> [[Int]] {
        guard segments.count > 1 else { return [] }
        let boxes = segments.map { ObstaclePolyline.bounds([$0.start, $0.end]).inflated(by: reach + tolerance) }
        let tree = QuadTree<Int>(bounds: boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }.inflated(by: 1))
        for (i, box) in boxes.enumerated() { tree.insert(bounds: box, item: i) }
        let candidates = RoutingCompute.current?.overlapMatrix(segments.map { (start: $0.start, end: $0.end) }, padding: reach + tolerance)
        var parent = Array(segments.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for (i, s) in segments.enumerated() {
            let near = candidates.map { m in (i + 1..<segments.count).filter { m[i * segments.count + $0] != 0 } } ?? tree.query(boxes[i]).filter { $0 > i }
            for j in near where segments[j].edge != s.edge && related(s, segments[j], reach: reach, spacing: spacing) {
                parent[root(j)] = root(i)
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in segments.indices { groups[root(i), default: []].append(i) }
        return groups.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
    }

    private static func related(_ s: Segment, _ t: Segment, reach: Double, spacing: Double) -> Bool {
        guard abs(cross(s.direction, t.direction)) <= angleLimit else { return false }
        // `t` in `s`'s frame: along the line and across it.
        let ta = dot(s.direction, t.start), tb = dot(s.direction, t.end), pa = dot(s.normal, t.start), pb = dot(s.normal, t.end)
        let base = dot(s.normal, s.start), low = min(ta, tb), high = max(ta, tb)
        let overlap = min(s.high, high) - max(s.low, low)
        guard overlap > -reach else { return false }
        func across(_ x: Double) -> Double { abs((abs(tb - ta) < tolerance ? (pa + pb) / 2 : pa + (pb - pa) * (x - ta) / (tb - ta)) - base) }
        if overlap > tolerance { return max(across(max(s.low, low)), across(min(s.high, high))) <= spacing + tolerance }
        let below = s.high <= low, aligned = dot(s.direction, t.direction) > 0
        let tLow = aligned ? t.lowBends : t.highBends, tHigh = aligned ? t.highBends : t.lowBends
        guard below ? s.highBends || tLow : tHigh || s.lowBends else { return false }
        return across(below ? low : high) <= spacing + tolerance
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

    /// Free width either side of a shared stretch: the nearer node on that side bounds it.
    /// Nodes further off than `reach` cannot narrow the spread, so only those are looked up.
    private static func room(_ u: Point, _ n: Point, _ c: Double, _ low: Double, _ high: Double, _ scene: ObstaclePolyline.Scene,
                             reach: Double) -> (minus: Double, plus: Double) {
        let window = ObstaclePolyline.bounds([(low, c - reach), (high, c - reach), (low, c + reach), (high, c + reach)].map { u * $0.0 + n * $0.1 })
        var minus = Double.infinity, plus = Double.infinity
        for i in scene.within(window) where !scene.nodes[i].isGroup {
            let r = scene.rects[i]
            let corners = [Point(x: r.left, y: r.top), Point(x: r.right, y: r.top), Point(x: r.left, y: r.bottom), Point(x: r.right, y: r.bottom)]
            let along = corners.map { dot(u, $0) }, across = corners.map { dot(n, $0) }
            guard min(high, along.max()!) - max(low, along.min()!) > tolerance else { continue }
            if across.max()! <= c + tolerance { minus = min(minus, c - across.max()!) }
            else if across.min()! >= c - tolerance { plus = min(plus, across.min()! - c) }
        }
        return (minus, plus)
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
        // Still heading the same way but the legs differ in length: the shorter one turns first while the other runs on.
        if i < a.count && i < b.count {
            let va = a[i] - c, vb = b[i] - c
            if va.length > tolerance, vb.length > tolerance, abs(cross(va, vb)) <= 1e-9 * va.length * vb.length, dot(va, vb) > 0 {
                let aFirst = va.length < vb.length, turner = aFirst ? a : b, heading = aFirst ? va : vb
                let turn = i + 1 < turner.count ? angle(heading, turner[i + 1] - turner[i]) : 0
                return aFirst ? turn : -turn
            }
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
            let denominator = cross(v1, v2), limit = min(4 * max(d1.length, d2.length), 0.5 * min(v1.length, v2.length))
            if abs(denominator) > 1e-12 * v1.length * v2.length {
                let corner = p1 + v1 * (cross(p2 - p1, v2) / denominator)
                // A right-angle bend keeps its exact corner (it cannot spike), so orthogonal routes stay orthogonal.
                if (corner - path[k]).length <= limit || abs(dot(v1, v2)) <= 1e-9 * v1.length * v2.length { result.append(corner); continue }
            }
            if dot(v1, v2) < 0 { result += [path[k] + d1, path[k] + d2] } else { result.append(path[k] + (d1 + d2) / 2) }
        }
        result.append(path[path.count - 1] + shifts[shifts.count - 1])
        return result
    }

    /// The stretch across a lane (along `n`) that keeps an end leg on the face it leaves: the face less an inset from its
    /// corners, widened to take in the leg's own position. Nil unless the segment is an axis-aligned first or last leg.
    private static func faceSpan(_ segment: Segment, _ paths: [[Point]], _ edges: [LayoutEdge], n: Point, spacing: Double) -> (low: Double, high: Double)? {
        guard abs(abs(n.x) - 1) < 1e-9 || abs(abs(n.y) - 1) < 1e-9 else { return nil }
        let path = paths[segment.edge], edge = edges[segment.edge]
        var spans: [(low: Double, high: Double)] = []
        for (isEnd, end, node) in [(segment.index == 0, path[0], edge.source), (segment.index == path.count - 2, path[path.count - 1], edge.target)] where isEnd {
            let r = node.bounds, horizontal = abs(n.y) > 0.5
            let onFace = horizontal ? (abs(end.x - r.left) <= tolerance || abs(end.x - r.right) <= tolerance) && end.y >= r.top - tolerance && end.y <= r.bottom + tolerance
                                    : (abs(end.y - r.top) <= tolerance || abs(end.y - r.bottom) <= tolerance) && end.x >= r.left - tolerance && end.x <= r.right + tolerance
            guard onFace else { continue }
            let a = dot(n, Point(x: r.left, y: r.top)), b = dot(n, Point(x: r.right, y: r.bottom)), low = min(a, b), high = max(a, b)
            let inset = min(spacing / 2, (high - low) / 4), here = dot(n, end)
            spans.append((min(low + inset, here), max(high - inset, here)))
        }
        guard let first = spans.first else { return nil }
        return spans.dropFirst().reduce(first) { (max($0.low, $1.low), min($0.high, $1.high)) }
    }

    /// Keeps a shifted end on its node. An end that left its node square to a face is clamped to the face less an inset
    /// from its corners, and the bend beside it moves with it, so the end leg stays square to the face.
    private static func anchor(_ path: inout [Point], _ original: [Point], atStart: Bool, inside bounds: Rect, spacing: Double) {
        let i = atStart ? 0 : path.count - 1, j = atStart ? 1 : path.count - 2
        guard path.count >= 2, original.count >= 2 else { return }
        let o = original[atStart ? 0 : original.count - 1], b = original[atStart ? 1 : original.count - 2]
        let moved = path[i]
        if bounds.contains(o), moved != o {
            if abs(o.y - b.y) <= tolerance, abs(o.x - b.x) > tolerance, abs(o.x - bounds.left) <= tolerance || abs(o.x - bounds.right) <= tolerance {
                let inset = min(spacing / 2, bounds.height / 4), y = min(max(moved.y, min(bounds.top + inset, o.y)), max(bounds.bottom - inset, o.y))
                if abs(y - moved.y) > tolerance, abs(path[j].y - moved.y) <= tolerance { path[i].y = y; path[j].y = y; return }
            } else if abs(o.x - b.x) <= tolerance, abs(o.y - b.y) > tolerance, abs(o.y - bounds.top) <= tolerance || abs(o.y - bounds.bottom) <= tolerance {
                let inset = min(spacing / 2, bounds.width / 4), x = min(max(moved.x, min(bounds.left + inset, o.x)), max(bounds.right - inset, o.x))
                if abs(x - moved.x) > tolerance, abs(path[j].x - moved.x) <= tolerance { path[i].x = x; path[j].x = x; return }
            }
        }
        path[i] = keep(path[i], original: o, inside: bounds)
    }

    /// An endpoint that started on or inside its node stays there after shifting.
    private static func keep(_ point: Point, original: Point, inside bounds: Rect) -> Point {
        guard bounds.contains(original), !bounds.contains(point) else { return point }
        return Point(x: min(max(point.x, bounds.left), bounds.right), y: min(max(point.y, bounds.top), bounds.bottom))
    }

    private struct Pair: Hashable { var low: ObjectIdentifier, high: ObjectIdentifier }
    private static func pair(_ edge: LayoutEdge) -> Pair {
        let a = ObjectIdentifier(edge.source), b = ObjectIdentifier(edge.target)
        return a < b ? Pair(low: a, high: b) : Pair(low: b, high: a)
    }
    private static func properCrossing(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        let u = b - a, v = d - c, denominator = cross(u, v)
        guard abs(denominator) > 1e-9 * u.length * v.length else { return false }
        let t = cross(c - a, v) / denominator, s = cross(c - a, u) / denominator
        return t > 1e-9 && t < 1 - 1e-9 && s > 1e-9 && s < 1 - 1e-9
    }
    /// Crossings between two paths.
    private static func crossings(_ p: [Point], _ q: [Point]) -> Int {
        zip(p, p.dropFirst()).reduce(0) { n, a in n + zip(q, q.dropFirst()).filter { properCrossing(a.0, a.1, $0, $1) }.count }
    }
    /// Crossings between non-adjacent segments of one path.
    private static func selfCrossings(_ path: [Point]) -> Int {
        let segments = Array(zip(path, path.dropFirst()))
        return segments.indices.reduce(0) { n, i in n + (i + 2..<max(i + 2, segments.count)).filter { properCrossing(segments[i].0, segments[i].1, segments[$0].0, segments[$0].1) }.count }
    }
    /// Vertices where the path turns back by more than 150 degrees.
    private static func reversals(_ path: [Point]) -> Int {
        (1..<max(1, path.count - 1)).filter { k in
            let u = path[k] - path[k - 1], v = path[k + 1] - path[k]
            return dot(u, v) < -0.866 * u.length * v.length
        }.count
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
