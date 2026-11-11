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
    public var spacing: Float = 10

    /// Unseparated edges still share a stretch after the last `routeEdges`: the corridor had no room for lanes, or the
    /// lanes would cut a node.
    public private(set) var report = RoutingReport()

    /// Edges still sharing a stretch after the last run: the corridor had no room for lanes, or the lanes would cut a
    /// node.
    @available(*, deprecated, message: "Use report.unseparated or report.unseparatedEdges(in:)")
    public var unseparatedEdges: [LayoutEdge] { unseparated }

    /// Edges still sharing a stretch after the last run, including runs over a subset through `separate`.
    private(set) var unseparated: [LayoutEdge] = []

    /// The most lanes any one shared stretch was spread over in the last run.
    private(set) var widestGroup = 0

    public init() {}

    private struct Segment {
        var edge: Int
        var index: Int
        var start: Point
        var end: Point
        var direction: Point
        var normal: Point
        var low: Float
        var high: Float

        /// Whether the low/high end is an interior bend, which moves along the line when its neighbour shifts.
        var lowBends: Bool
        var highBends: Bool
    }

    private static let tolerance: Float = 1e-5

    /// Segments this close in direction count as running the same way.
    private static let angleLimit = Float(sin(2 * Double.pi / 180))

    public func routeEdges(_ graph: LayoutGraph) {
        separate(graph.edges, ObstaclePolyline.Scene(graph.nodes))
        report = RoutingReport(graph, unseparated: unseparated)
    }

    func separate(_ all: [LayoutEdge], _ scene: ObstaclePolyline.Scene) {
        unseparated = []
        report = RoutingReport()
        widestGroup = 0
        guard spacing > 0, spacing.isFinite else { return }
        let edges = all.filter { $0.source !== $0.target }
        let paths = edges.map { Self.simplified($0.path) }
        var segments: [Segment] = []
        for (e, path) in paths.enumerated() where path.count >= 2 {
            for k in path.indices.dropLast() {
                let a = path[k]
                let b = path[k + 1]
                let delta = b - a
                var u = delta / delta.length
                // One canonical direction per line, so reciprocal edges land on the same track.
                if u.x < -1e-6 || (abs(u.x) <= 1e-6 && u.y < 0) { u = u * -1 }
                let ta = Self.dot(u, a)
                let tb = Self.dot(u, b)
                let startBends = k > 0
                let endBends = k + 2 < path.count
                segments.append(
                    Segment(
                        edge: e,
                        index: k,
                        start: a,
                        end: b,
                        direction: u,
                        normal: Point(x: -u.y, y: u.x),
                        low: min(ta, tb),
                        high: max(ta, tb),
                        lowBends: ta <= tb ? startBends : endBends,
                        highBends: ta <= tb ? endBends : startBends
                    )
                )
            }
        }
        if RoutingCompute.isCancelled { return }
        // Runs that nearly meet at a bend count as shared: once that bend moves to its lane,
        // the runs would otherwise be pushed into each other. Runs meeting only at path ends stay apart.
        let reach = 2 * spacing
        let groups = LayoutStageScope.run("Shared runs", to: 0.2) {
            Self.sharedGroups(segments, reach: reach, spacing: spacing)
        }
        let lanes = LayoutStageScope.begin("Lanes", from: 0.2, to: 0.5)
        var shifts = paths.map { Array(repeating: Point.zero, count: max(0, $0.count - 1)) }
        var shiftGroup = paths.map { Array(repeating: -1, count: max(0, $0.count - 1)) }
        var cramped = Set<Int>()
        for (g, group) in groups.enumerated() {
            if RoutingCompute.isCancelled { return }
            lanes.tick(g, of: groups.count)
            let u = segments[group[0]].direction
            let n = segments[group[0]].normal
            var spans: [Int: (low: Float, high: Float, first: Int)] = [:]
            var runs: [Int: [(Float, Float)]] = [:]
            var perpendicular: Float = 0.0
            for s in group {
                let segment = segments[s]
                let ta = Self.dot(u, segment.start)
                let tb = Self.dot(u, segment.end)
                perpendicular += Self.dot(n, segment.start + segment.end) / 2
                runs[segment.edge, default: []].append((min(ta, tb), max(ta, tb)))
                if let span = spans[segment.edge] {
                    spans[segment.edge] = (
                        min(span.low, ta, tb), max(span.high, ta, tb), min(span.first, segment.index)
                    )
                } else {
                    spans[segment.edge] = (min(ta, tb), max(ta, tb), segment.index)
                }
            }
            guard spans.count > 1 else { continue }
            let centre = perpendicular / Float(group.count)
            // Insertion sort: the pairwise order need not be transitive when some crossing is unavoidable.
            // Each edge's trails either way from its first shared segment are built once, not on every comparison.
            let members = spans.keys.sorted()
            let trails = members.map { e in
                let k = spans[required: e].first
                return Trails(
                    path: paths[e],
                    k: k,
                    ahead: Self.trail(paths[e], k, u, true),
                    behind: Self.trail(paths[e], k, u, false)
                )
            }
            // Positions in `members`, so comparisons index arrays instead of hashing edge numbers.
            var order: [Int] = []
            for m in members.indices {
                let position =
                    order.firstIndex { Self.precedes(members[m], members[$0], trails[m], trails[$0], u) } ?? order.count
                order.insert(m, at: position)
            }
            let ordered = order.map { members[$0] }
            // Monotone lanes: an edge sits one lane beyond every earlier edge with a run within `reach` of one of its
            // own, so lanes keep the crossing-free order; edges whose runs are well apart along the line share a lane.
            // An earlier edge is only tested when it could raise the lane, and only when its whole span is within
            // reach.
            var lane: [Int: Int] = [:]
            var count = 1
            let orderedRuns = ordered.map { runs[required: $0] }
            let orderedSpans = ordered.map { spans[required: $0] }
            var orderedLanes: [Int] = []
            for (i, e) in ordered.enumerated() {
                var l = 0
                for f in 0..<i
                where orderedLanes[f] + 1 > l
                    && Self.overlaps(
                        (orderedSpans[f].low, orderedSpans[f].high),
                        (orderedSpans[i].low, orderedSpans[i].high),
                        reach: reach
                    )
                    && orderedRuns[f]
                        .contains(where: { a in orderedRuns[i].contains { Self.overlaps(a, $0, reach: reach) } })
                {
                    l = orderedLanes[f] + 1
                }
                orderedLanes.append(l)
                lane[e] = l
                count = max(count, l + 1)
            }
            guard count > 1 else { continue }
            // Lanes sit `spacing` apart about the group. A node beside it pushes them to the open side, keeping a full
            // spacing from it if that still fits and half a spacing otherwise; a corridor too narrow for 1pt lanes
            // stays merged.
            // The guard above leaves more than one span.
            let low = spans.values.map(\.low).min()!
            let high = spans.values.map(\.high).max()!
            let room = Self.room(u, n, centre, low, high, scene, reach: Float(count + 1) * spacing)
            let span = Float(count - 1) * spacing
            // A lane that leaves a node square to its face must stay on the face, clear of its corners.
            let faces = group.compactMap { Self.faceSpan(segments[$0], paths, edges, n: n, spacing: spacing) }
            let faceLow = faces.map(\.low).max() ?? -.infinity
            let faceHigh = faces.map(\.high).min() ?? .infinity
            // The lanes' window is the corridor between the nearest nodes (less `reserve`) within the faces: centred on
            // the group and slid along it to fit, or drawn closer together when it is narrower than the full spread.
            func place(_ reserve: Float) -> (first: Float, step: Float) {
                let limit = 4 * spacing
                let low = max(centre - min(limit, max(room.minus - reserve, 0)), faceLow)
                let high = min(centre + min(limit, max(room.plus - reserve, 0)), faceHigh)
                guard high >= low else { return (centre, 0) }
                if high - low >= span - 1e-5 { return (min(max(centre - span / 2, low), high - span), spacing) }
                return (low, (high - low) / Float(count - 1))
            }
            var (first, step) = place(spacing)
            if step < spacing - 1e-5 { (first, step) = place(spacing / 2) }
            guard step >= 1 else {
                cramped.formUnion(spans.keys)
                continue
            }
            widestGroup = max(widestGroup, count)
            for s in group {
                let segment = segments[s]
                let position = first + Float(lane[required: segment.edge]) * step
                let shift = n * (position - Self.dot(n, segment.start + segment.end) / 2)
                if shift.length <= 4 * spacing + Self.tolerance {
                    shifts[segment.edge][segment.index] = shift
                    shiftGroup[segment.edge][segment.index] = g
                } else {
                    cramped.insert(segment.edge)
                }
            }
        }
        if RoutingCompute.isCancelled { return }
        lanes.end()
        let shifting = LayoutStageScope.begin("Shifts", from: 0.5, to: 0.95)
        let originals = edges.map(\.path)
        let twinGroups = Dictionary(grouping: edges.indices) { Self.pair(edges[$0]) }
        func build(_ e: Int, _ chosen: Set<Int>) -> [Point] {
            var path = Self.shifted(paths[e], zip(shifts[e], shiftGroup[e]).map { chosen.contains($1) ? $0 : .zero })
            Self.anchor(&path, paths[e], atStart: true, inside: edges[e].source.bounds, spacing: spacing)
            Self.anchor(&path, paths[e], atStart: false, inside: edges[e].target.bounds, spacing: spacing)
            return path
        }
        func moving(_ e: Int) -> [Int] { Set(zip(shifts[e], shiftGroup[e]).filter { $0.0 != .zero }.map(\.1)).sorted() }
        // Where every edge would sit with all its shifts: an edge is judged against the twins it will meet, not their
        // old routes.
        let proposed = edges.indices.map { moving($0).isEmpty ? originals[$0] : build($0, Set(moving($0))) }
        for (e, edge) in edges.enumerated() where shifts[e].contains(where: { $0 != .zero }) {
            shifting.tick(e, of: edges.count)
            let moving = moving(e)
            let all = proposed[e]
            let area = ObstaclePolyline.bounds(edge.path + all).inflated(by: 1)
            let obstacles = scene.near(area, edge).map { scene.rects[$0].inflated(by: -Self.tolerance) }
                .filter { $0.width > 0 && $0.height > 0 }
            let before = Self.hits(edge.path, obstacles)
            // A shift is kept only if it leaves the route no worse: no new node cut, self-crossing, U-turn,
            // or crossing with an edge joining the same two nodes.
            let twins = twinGroups[required: Self.pair(edge)].filter { $0 != e }
                .map { $0 < e ? edges[$0].path : proposed[$0] }
            let baseline = (
                Self.selfCrossings(edge.path), Self.reversals(edge.path), twins.map { Self.crossings(edge.path, $0) }
            )
            func acceptable(_ path: [Point]) -> Bool {
                let envelope = ObstaclePolyline.bounds(paths[e]).inflated(by: 4 * spacing + Self.tolerance)
                return path.allSatisfy(envelope.contains) && Self.hits(path, obstacles).isSubset(of: before)
                    && Self.selfCrossings(path) <= baseline.0 && Self.reversals(path) <= baseline.1
                    && zip(twins, baseline.2).allSatisfy { Self.crossings(path, $0) <= $1 }
            }
            if acceptable(all) {
                edge.path = all
                continue
            }
            // Keep each group's shift that passes, and drop the rest.
            var chosen = Set<Int>()
            for g in moving where acceptable(build(e, chosen.union([g]))) { chosen.insert(g) }
            if !chosen.isEmpty { edge.path = build(e, chosen) }
            if chosen.count < moving.count { cramped.insert(e) }
        }
        shifting.end()
        // Touching points are not crossings, so an edge shifted against its twin's old route can still end up crossing
        // its twin's new one. Any pair that ends up crossing more than it started puts the later edge back.
        for list in twinGroups.values.filter({ $0.count > 1 }).sorted(by: { $0[0] < $1[0] }) {
            var changed = true
            while changed {
                changed = false
                for (a, i) in list.enumerated() {
                    for j in list[(a + 1)...]
                    where Self.crossings(edges[i].path, edges[j].path) > Self.crossings(originals[i], originals[j]) {
                        let back = edges[j].path != originals[j] ? j : i
                        edges[back].path = originals[back]
                        cramped.insert(back)
                        changed = true
                    }
                }
            }
        }
        unseparated = edges.indices.filter(cramped.contains).map { edges[$0] }
    }

    /// Removes repeated points and straight-through interior points so each segment is a maximal straight run.
    private static func simplified(_ path: [Point]) -> [Point] {
        var result: [Point] = []
        for p in path {
            if let last = result.last, (p - last).length <= tolerance { continue }
            if result.count >= 2 {
                let a = result[result.count - 2]
                let b = result[result.count - 1]
                let u = b - a
                let v = p - b
                if abs(cross(u, v)) <= tolerance * u.length * v.length && dot(u, v) > 0 {
                    result[result.count - 1] = p
                    continue
                }
            }
            result.append(p)
        }
        return result
    }

    /// Unions segments of different edges that run the same way (within `angleLimit`, and `spacing` apart across
    /// the stretch they share) and overlap, or come within `reach` of each other at a bend.
    private static func sharedGroups(_ segments: [Segment], reach: Float, spacing: Float) -> [[Int]] {
        guard segments.count > 1 else { return [] }
        let candidates = RoutingCompute.current?
            .overlapPairs(segments.map { (start: $0.start, end: $0.end) }, padding: reach + tolerance)
        var parent = Array(segments.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        // Bundled corridors relate millions of pairs that are mostly in one group already; only a pair from two
        // different groups can change the result, so the geometric test is skipped for the rest.
        func join(_ i: Int, _ j: Int) {
            guard segments[j].edge != segments[i].edge else { return }
            let a = root(i)
            let b = root(j)
            if a != b && related(segments[i], segments[j], reach: reach, spacing: spacing) { parent[b] = a }
        }
        if let candidates {
            for i in segments.indices { for j in candidates[i] { join(i, j) } }
        } else {
            let boxes = segments.map { ObstaclePolyline.bounds([$0.start, $0.end]).inflated(by: reach + tolerance) }
            for (i, j) in boxPairs(segments, boxes) { join(min(i, j), max(i, j)) }
        }
        var groups: [Int: [Int]] = [:]
        for i in segments.indices { groups[root(i), default: []].append(i) }
        return groups.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
    }

    /// Every pair of segments whose boxes overlap (strictly, as `Rect.intersects`) and whose directions could pass
    /// `related`'s angle test. Canonical directions are binned by angle in steps of twice the angle limit, so such
    /// a pair always lies in one bin or two neighbouring ones (the bins wrap at vertical). Within a bin pair the
    /// boxes are swept along the axis across the bin's direction, where corridor segments are thin.
    private static func boxPairs(_ segments: [Segment], _ boxes: [Rect]) -> [(Int, Int)] {
        let binDegrees: Float = 4
        let binCount = Int(180 / binDegrees)
        var bins = Array(repeating: [Int](), count: binCount)
        var binOf = Array(repeating: -1, count: segments.count)
        for (i, s) in segments.enumerated() {
            let degrees = atan2(s.direction.y, s.direction.x) * 180 / .pi + 90
            // A direction without an angle cannot pass the angle test, so it pairs with nothing.
            guard degrees.isFinite else { continue }
            let bin = ((Int((degrees / binDegrees).rounded(.down)) % binCount) + binCount) % binCount
            bins[bin].append(i)
            binOf[i] = bin
        }
        var pairs: [(Int, Int)] = []
        for b in bins.indices where !bins[b].isEmpty {
            let next = (b + 1) % binCount
            // Near-horizontal bins are thin in y, near-vertical ones in x.
            let acrossY = abs(Float(b) * binDegrees + binDegrees / 2 - 90) < 45
            func low(_ i: Int) -> Float { acrossY ? boxes[i].top : boxes[i].left }
            func high(_ i: Int) -> Float { acrossY ? boxes[i].bottom : boxes[i].right }
            func alongOverlap(_ i: Int, _ j: Int) -> Bool {
                acrossY
                    ? boxes[i].left < boxes[j].right && boxes[i].right > boxes[j].left
                    : boxes[i].top < boxes[j].bottom && boxes[i].bottom > boxes[j].top
            }
            // Pairs inside bin `b`, and between `b` and the next bin; pairs inside the next bin are its own.
            let members = (next == b ? bins[b] : bins[b] + bins[next]).sorted { low($0) < low($1) }
            for (k, i) in members.enumerated() {
                for j in members[(k + 1)...] {
                    // Sorted by low edge: once one starts past this box's high edge, all later ones do too.
                    guard low(j) < high(i) else { break }
                    if (binOf[i] == b || binOf[j] == b) && high(j) > low(i) && alongOverlap(i, j) {
                        pairs.append((i, j))
                    }
                }
            }
        }
        return pairs
    }

    private static func related(_ s: Segment, _ t: Segment, reach: Float, spacing: Float) -> Bool {
        guard abs(cross(s.direction, t.direction)) <= angleLimit else { return false }
        // `t` in `s`'s frame: along the line and across it.
        let ta = dot(s.direction, t.start)
        let tb = dot(s.direction, t.end)
        let pa = dot(s.normal, t.start)
        let pb = dot(s.normal, t.end)
        let base = dot(s.normal, s.start)
        let low = min(ta, tb)
        let high = max(ta, tb)
        let overlap = min(s.high, high) - max(s.low, low)
        guard overlap > -reach else { return false }
        func across(_ x: Float) -> Float {
            abs((abs(tb - ta) < tolerance ? (pa + pb) / 2 : pa + (pb - pa) * (x - ta) / (tb - ta)) - base)
        }
        if overlap > tolerance { return max(across(max(s.low, low)), across(min(s.high, high))) <= spacing + tolerance }
        let below = s.high <= low
        let aligned = dot(s.direction, t.direction) > 0
        let tLow = aligned ? t.lowBends : t.highBends
        let tHigh = aligned ? t.highBends : t.lowBends
        guard below ? s.highBends || tLow : tHigh || s.lowBends else { return false }
        return across(below ? low : high) <= spacing + tolerance
    }

    /// Whether edge `a` belongs on the `-n` side of edge `b`. Both trails are followed past the shared stretch
    /// until they part, so consecutive shared stretches agree on the order; the leaving end decides, then the
    /// arriving end, then edge order.
    /// One edge's path either side of its first segment in a shared group, in the group's canonical direction.
    private struct Trails { var path: [Point], k: Int, ahead: [Point], behind: [Point] }

    private static func precedes(_ a: Int, _ b: Int, _ ta: Trails, _ tb: Trails, _ u: Point) -> Bool {
        for ahead in [true, false] {
            let turn = parting(ahead ? ta.ahead : ta.behind, ahead ? tb.ahead : tb.behind, ahead ? u : u * -1)
            if abs(turn) > 1e-5 { return ahead ? turn < 0 : turn > 0 }
        }
        // Paths that never part: the lower-index edge keeps to the left of its own travel, which stays
        // consistent round corners, unlike a fixed side of each track.
        let lower = a < b ? ta : tb
        let forward = dot(lower.path[lower.k + 1] - lower.path[lower.k], u) > 0
        return (a < b) ? !forward : forward
    }

    /// Free width either side of a shared stretch: the nearer node on that side bounds it.
    /// Nodes further off than `reach` cannot narrow the spread, so only those are looked up.
    private static func room(
        _ u: Point,
        _ n: Point,
        _ c: Float,
        _ low: Float,
        _ high: Float,
        _ scene: ObstaclePolyline.Scene,
        reach: Float
    ) -> (minus: Float, plus: Float) {
        let window = ObstaclePolyline.bounds(
            [(low, c - reach), (high, c - reach), (low, c + reach), (high, c + reach)].map { u * $0.0 + n * $0.1 }
        )
        var minus = Float.infinity
        var plus = Float.infinity
        for i in scene.within(window) where !scene.nodes[i].isGroup {
            let r = scene.rects[i]
            let corners = [
                Point(x: r.left, y: r.top), Point(x: r.right, y: r.top), Point(x: r.left, y: r.bottom),
                Point(x: r.right, y: r.bottom),
            ]
            let along = corners.map { dot(u, $0) }
            let across = corners.map { dot(n, $0) }
            // `corners` always holds four points, so `along` and `across` are non-empty.
            guard min(high, along.max()!) - max(low, along.min()!) > tolerance else { continue }
            if across.max()! <= c + tolerance {
                minus = min(minus, c - across.max()!)
            } else if across.min()! >= c - tolerance {
                plus = min(plus, across.min()! - c)
            }
        }
        return (minus, plus)
    }

    /// The path beyond a shared segment, starting at its end in the canonical direction (`ahead`) or its start.
    private static func trail(_ path: [Point], _ k: Int, _ u: Point, _ ahead: Bool) -> [Point] {
        (dot(path[k + 1] - path[k], u) > 0) == ahead ? Array(path[(k + 1)...]) : Array(path[...k].reversed())
    }

    /// Signed angle by which trail `a` parts counter-clockwise of trail `b`, both travelling along `direction`.
    private static func parting(_ a: [Point], _ b: [Point], _ direction: Point) -> Float {
        func angle(_ d: Point, _ v: Point) -> Float { v.length <= tolerance ? 0 : atan2(cross(d, v), dot(d, v)) }
        // Ends at different points on the shared line: the nearer one turns first while the other runs on.
        if (a[0] - b[0]).length > tolerance {
            let aFirst = dot(direction, a[0]) < dot(direction, b[0])
            let turner = aFirst ? a : b
            let turn = turner.count > 1 ? angle(direction, turner[1] - turner[0]) : 0
            return aFirst ? turn : -turn
        }
        var c = a[0]
        var d = direction
        var i = 1
        while i < a.count && i < b.count && (a[i] - b[i]).length <= tolerance {
            if (a[i] - c).length > tolerance { d = (a[i] - c) / (a[i] - c).length }
            c = a[i]
            i += 1
        }
        // Still heading the same way but the legs differ in length: the shorter one turns first while the other runs
        // on.
        if i < a.count && i < b.count {
            let va = a[i] - c
            let vb = b[i] - c
            if va.length > tolerance, vb.length > tolerance, abs(cross(va, vb)) <= 1e-5 * va.length * vb.length,
                dot(va, vb) > 0
            {
                let aFirst = va.length < vb.length
                let turner = aFirst ? a : b
                let heading = aFirst ? va : vb
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
            let d1 = shifts[k - 1]
            let d2 = shifts[k]
            if d1 == d2 {
                result.append(path[k] + d1)
                continue
            }
            let p1 = path[k - 1] + d1
            let v1 = path[k] - path[k - 1]
            let p2 = path[k] + d2
            let v2 = path[k + 1] - path[k]
            // An axis-aligned right angle takes its corner straight from the two shifted legs. The general intersection
            // below multiplies in Float, which can leave the corner an ulp off one leg (y = -19.999992 against -20) and
            // turn an orthogonal run into a slightly diagonal one.
            if v1.x == 0 && v1.y != 0 && v2.y == 0 && v2.x != 0 {
                result.append(Point(x: p1.x, y: p2.y))
                continue
            }
            if v1.y == 0 && v1.x != 0 && v2.x == 0 && v2.y != 0 {
                result.append(Point(x: p2.x, y: p1.y))
                continue
            }
            let denominator = cross(v1, v2)
            let limit = min(4 * max(d1.length, d2.length), 0.5 * min(v1.length, v2.length))
            if abs(denominator) > 1e-6 * v1.length * v2.length {
                let corner = p1 + v1 * (cross(p2 - p1, v2) / denominator)
                // A right-angle bend keeps its exact corner (it cannot spike), so orthogonal routes stay orthogonal.
                if (corner - path[k]).length <= limit || abs(dot(v1, v2)) <= 1e-5 * v1.length * v2.length {
                    result.append(corner)
                    continue
                }
            }
            if dot(v1, v2) < 0 {
                result += [path[k] + d1, path[k] + d2]
            } else {
                result.append(path[k] + (d1 + d2) / 2)
            }
        }
        result.append(path[path.count - 1] + shifts[shifts.count - 1])
        return result
    }

    /// The stretch across a lane (along `n`) that keeps an end leg on the face it leaves: the face less an inset from
    /// its
    /// corners, widened to take in the leg's own position. Nil unless the segment is an axis-aligned first or last leg.
    private static func faceSpan(
        _ segment: Segment,
        _ paths: [[Point]],
        _ edges: [LayoutEdge],
        n: Point,
        spacing: Float
    ) -> (low: Float, high: Float)? {
        guard abs(abs(n.x) - 1) < 1e-5 || abs(abs(n.y) - 1) < 1e-5 else { return nil }
        let path = paths[segment.edge]
        let edge = edges[segment.edge]
        var spans: [(low: Float, high: Float)] = []
        for (isEnd, end, node) in [
            (segment.index == 0, path[0], edge.source),
            (segment.index == path.count - 2, path[path.count - 1], edge.target),
        ] where isEnd {
            let r = node.bounds
            let horizontal = abs(n.y) > 0.5
            let onFace =
                horizontal
                ? (abs(end.x - r.left) <= tolerance || abs(end.x - r.right) <= tolerance) && end.y >= r.top - tolerance
                    && end.y <= r.bottom + tolerance
                : (abs(end.y - r.top) <= tolerance || abs(end.y - r.bottom) <= tolerance) && end.x >= r.left - tolerance
                    && end.x <= r.right + tolerance
            guard onFace else { continue }
            let a = dot(n, Point(x: r.left, y: r.top))
            let b = dot(n, Point(x: r.right, y: r.bottom))
            let low = min(a, b)
            let high = max(a, b)
            let inset = min(spacing / 2, (high - low) / 4)
            let here = dot(n, end)
            spans.append((min(low + inset, here), max(high - inset, here)))
        }
        guard let first = spans.first else { return nil }
        return spans.dropFirst().reduce(first) { (max($0.low, $1.low), min($0.high, $1.high)) }
    }

    /// Keeps a shifted end on its node. An end that left its node square to a face is clamped to the face less an inset
    /// from its corners, and the bend beside it moves with it, so the end leg stays square to the face.
    private static func anchor(
        _ path: inout [Point],
        _ original: [Point],
        atStart: Bool,
        inside bounds: Rect,
        spacing: Float
    ) {
        let i = atStart ? 0 : path.count - 1
        let j = atStart ? 1 : path.count - 2
        guard path.count >= 2, original.count >= 2 else { return }
        let o = original[atStart ? 0 : original.count - 1]
        let b = original[atStart ? 1 : original.count - 2]
        let moved = path[i]
        if bounds.contains(o), moved != o {
            if abs(o.y - b.y) <= tolerance, abs(o.x - b.x) > tolerance,
                abs(o.x - bounds.left) <= tolerance || abs(o.x - bounds.right) <= tolerance
            {
                let inset = min(spacing / 2, bounds.height / 4)
                let y = min(max(moved.y, min(bounds.top + inset, o.y)), max(bounds.bottom - inset, o.y))
                if abs(y - moved.y) > tolerance, abs(path[j].y - moved.y) <= tolerance {
                    path[i].y = y
                    path[j].y = y
                    return
                }
            } else if abs(o.x - b.x) <= tolerance, abs(o.y - b.y) > tolerance,
                abs(o.y - bounds.top) <= tolerance || abs(o.y - bounds.bottom) <= tolerance
            {
                let inset = min(spacing / 2, bounds.width / 4)
                let x = min(max(moved.x, min(bounds.left + inset, o.x)), max(bounds.right - inset, o.x))
                if abs(x - moved.x) > tolerance, abs(path[j].x - moved.x) <= tolerance {
                    path[i].x = x
                    path[j].x = x
                    return
                }
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
        let a = ObjectIdentifier(edge.source)
        let b = ObjectIdentifier(edge.target)
        return a < b ? Pair(low: a, high: b) : Pair(low: b, high: a)
    }

    private static func properCrossing(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        let u = b - a
        let v = d - c
        let denominator = cross(u, v)
        guard abs(denominator) > 1e-5 * u.length * v.length else { return false }
        let t = cross(c - a, v) / denominator
        let s = cross(c - a, u) / denominator
        return t > 1e-5 && t < 1 - 1e-5 && s > 1e-5 && s < 1 - 1e-5
    }

    /// Crossings between two paths.
    private static func crossings(_ p: [Point], _ q: [Point]) -> Int {
        zip(p, p.dropFirst())
            .reduce(0) { n, a in n + zip(q, q.dropFirst()).filter { properCrossing(a.0, a.1, $0, $1) }.count }
    }

    /// Crossings between non-adjacent segments of one path.
    private static func selfCrossings(_ path: [Point]) -> Int {
        let segments = Array(zip(path, path.dropFirst()))
        return segments.indices.reduce(0) { n, i in
            n
                + (i + 2..<max(i + 2, segments.count))
                .filter { properCrossing(segments[i].0, segments[i].1, segments[$0].0, segments[$0].1) }.count
        }
    }

    /// Vertices where the path turns back by more than 150 degrees.
    private static func reversals(_ path: [Point]) -> Int {
        (1..<max(1, path.count - 1))
            .filter { k in
                let u = path[k] - path[k - 1]
                let v = path[k + 1] - path[k]
                return dot(u, v) < -0.866 * u.length * v.length
            }
            .count
    }

    private static func hits(_ path: [Point], _ obstacles: [Rect]) -> Set<Int> {
        if let compute = RoutingCompute.current {
            return compute.hits(path, obstacles)
        }
        return Set(
            obstacles.indices.filter { i in zip(path, path.dropFirst()).contains { obstacles[i].intersectsLine($0, $1) }
            }
        )
    }

    private static func overlaps(_ a: (Float, Float), _ b: (Float, Float), reach: Float) -> Bool {
        min(a.1, b.1) - max(a.0, b.0) > -reach
    }

    private static func dot(_ a: Point, _ b: Point) -> Float { a.x * b.x + a.y * b.y }

    private static func cross(_ a: Point, _ b: Point) -> Float { a.x * b.y - a.y * b.x }
}
