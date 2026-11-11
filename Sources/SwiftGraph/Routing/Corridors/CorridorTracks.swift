import Foundation

/// Gives every orthogonal route that shares a corridor a track of its own, after routing. Stretches of different
/// edges running along the same line, or closer than `spacing`, form a corridor; `TrackAllocation` orders them so
/// their arms cross as little as possible, and the tracks sit `spacing` apart about the corridor's routes, at least
/// `clearance` from the nodes either side. A corridor too narrow for that spreads its tracks evenly across the whole
/// gap. Moving a stretch moves the bends at its ends along its neighbours, so routes stay orthogonal, and a stretch
/// that leaves or enters a node stays on that node's face.
///
/// A route that would newly cut a node, or cross more edges outside its corridors than it did, keeps its merged route
/// and is reported. Routes with a diagonal stretch, and self-loops, are left alone.
struct CorridorTracks {
    private struct Run {
        var edge: Int
        var index: Int
        var vertical: Bool
        var at: Float
        var source: Float
        var target: Float
        var sourceSide: TrackSegment.Side?
        var targetSide: TrackSegment.Side?

        /// The free gap across the run, and for a run leaving or entering a node, that node's face.
        var gap: (low: Float, high: Float)
        var face: (low: Float, high: Float, inset: Float)?

        var low: Float { min(source, target) }
        var high: Float { max(source, target) }
    }

    let spacing: Float
    let clearance: Float
    let walls: CorridorWalls

    private static let tolerance: Float = 1e-3

    /// Moves the routes of `edges` onto their tracks and returns the edges still sharing a stretch with another.
    func assign(_ edges: [LayoutEdge], scene: ObstaclePolyline.Scene) -> [LayoutEdge] {
        guard spacing > 0, spacing.isFinite else { return [] }
        let routed = edges.filter { $0.source !== $0.target && $0.path.count >= 2 }
        let paths = routed.map { Self.simplified($0.path) }
        var runs: [Run] = []
        for (e, path) in paths.enumerated() where Self.isOrthogonal(path) {
            runs += self.runs(of: routed[e], e, path)
        }
        guard runs.count > 1 else { return [] }
        var parent = Array(runs.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func join(_ i: Int, _ j: Int) {
            let a = root(i)
            let b = root(j)
            if a != b { parent[max(a, b)] = min(a, b) }
        }
        let original = runs.map(\.at)
        // A corridor is every run in one bounded gap whose extent overlaps another's, plus runs closer than `spacing`
        // anywhere, such as those along the open outside of the drawing.
        for (i, j) in Self.closePairs(runs, original, within: spacing) { join(i, j) }
        for (i, j) in Self.sharedGaps(runs) { join(i, j) }
        let neighbours = Neighbours(runs)
        var positions = original
        var cramped = Set<Int>()
        let groups = Dictionary(grouping: runs.indices, by: root)
        for key in groups.keys.sorted() {
            if RoutingCompute.isCancelled { return [] }
            guard let members = groups[key], members.count > 1 else { continue }
            guard let placed = place(members, runs, neighbours) else {
                cramped.insert(key)
                continue
            }
            for (m, position) in placed { positions[m] = position }
        }
        var moved = paths
        for (r, run) in runs.enumerated() where positions[r] != run.at {
            if run.vertical {
                moved[run.edge][run.index].x = positions[r]
                moved[run.edge][run.index + 1].x = positions[r]
            } else {
                moved[run.edge][run.index].y = positions[r]
                moved[run.edge][run.index + 1].y = positions[r]
            }
        }
        let groupSizes = groups.mapValues(\.count)
        var corridors = Array(repeating: Set<Int>(), count: routed.count)
        for r in runs.indices where groupSizes[root(r), default: 0] > 1 { corridors[runs[r].edge].insert(root(r)) }
        var unseparated = Set(runs.indices.filter { cramped.contains(root($0)) }.map { runs[$0].edge })
        let merged = routed.map(\.path)
        var current = merged
        for e in routed.indices where moved[e] != paths[e] {
            let path = Self.simplified(moved[e])
            let clearBefore = scene.clear(merged[e], routed[e])
            if (!clearBefore || scene.clear(path, routed[e]))
                && Self.selfCrossings(path) <= Self.selfCrossings(merged[e])
            {
                current[e] = path
            } else {
                unseparated.insert(e); if ProcessInfo.processInfo.environment["CDBG"] != nil { print("CDBG hit-or-self", e) }
            }
        }
        // A track must not add crossings with edges outside its corridors (lanes within one corridor are ordered
        // by the allocation instead). An edge that would keeps its merged route; that can tip another, so repeat.
        let unrelated = { (e: Int, f: Int) in corridors[e].isDisjoint(with: corridors[f]) }
        var changed = true
        while changed {
            if RoutingCompute.isCancelled { return [] }
            changed = false
            for e in routed.indices where current[e] != merged[e] {
                var before = 0
                var after = 0
                let area = ObstaclePolyline.bounds(current[e] + merged[e])
                for f in routed.indices where f != e && unrelated(e, f) {
                    guard ObstaclePolyline.bounds(current[f] + merged[f]).inflated(by: 1).intersects(area) else {
                        continue
                    }
                    before += Self.crossings(merged[e], merged[f])
                    after += Self.crossings(current[e], current[f])
                }
                if after > before {
                    current[e] = merged[e]
                    unseparated.insert(e); if ProcessInfo.processInfo.environment["CDBG"] != nil { print("CDBG crossing", e, before, after) }
                    changed = true
                }
            }
        }
        for e in routed.indices { routed[e].path = current[e] }
        return routed.indices.filter { unseparated.contains($0) && !corridors[$0].isEmpty }.map { routed[$0] }
    }

    // MARK: - Runs

    private func runs(of edge: LayoutEdge, _ e: Int, _ path: [Point]) -> [Run] {
        var result: [Run] = []
        for k in path.indices.dropLast() {
            let a = path[k]
            let b = path[k + 1]
            let vertical = abs(a.x - b.x) <= Self.tolerance
            func across(_ p: Point) -> Float { vertical ? p.x : p.y }
            func along(_ p: Point) -> Float { vertical ? p.y : p.x }
            let at = across(a)
            func side(_ p: Point) -> TrackSegment.Side { across(p) < at ? .low : .high }
            let gap = walls.gap(vertical: vertical, at: at, from: min(along(a), along(b)), to: max(along(a), along(b)))
            var run = Run(
                edge: e,
                index: k,
                vertical: vertical,
                at: at,
                source: along(a),
                target: along(b),
                sourceSide: k > 0 ? side(path[k - 1]) : nil,
                targetSide: k + 2 < path.count ? side(path[k + 2]) : nil,
                gap: (gap.low, gap.high)
            )
            // A stretch leaving or entering a node stays on that node's face, clear of its corners.
            var ends: [LayoutNode] = []
            if k == 0 { ends.append(edge.source) }
            if k + 2 == path.count { ends.append(edge.target) }
            for node in ends {
                let r = node.bounds
                let (low, high) = vertical ? (r.left, r.right) : (r.top, r.bottom)
                let inset = min(spacing, (high - low) / 4)
                let face = run.face ?? (-.infinity, .infinity, inset)
                run.face = (max(face.low, low), min(face.high, high), min(face.inset, inset))
            }
            result.append(run)
        }
        return result
    }

    /// Pairs of runs on the same axis whose positions are within `distance` and whose extents overlap.
    private static func closePairs(_ runs: [Run], _ positions: [Float], within distance: Float) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        for vertical in [false, true] {
            let order = runs.indices.filter { runs[$0].vertical == vertical }.sorted { positions[$0] < positions[$1] }
            for (n, i) in order.enumerated() {
                for j in order[(n + 1)...] {
                    guard positions[j] - positions[i] < distance - tolerance else { break }
                    if min(runs[i].high, runs[j].high) - max(runs[i].low, runs[j].low) > tolerance {
                        pairs.append((i, j))
                    }
                }
            }
        }
        return pairs
    }

    /// Pairs of runs on the same axis in the same bounded gap whose extents overlap.
    private static func sharedGaps(_ runs: [Run]) -> [(Int, Int)] {
        struct Key: Hashable {
            var vertical: Bool
            var low: Int
            var high: Int
        }
        func quantize(_ value: Float) -> Int { Int((value * 8).rounded()) }
        let bounded = runs.indices.filter { runs[$0].gap.low.isFinite && runs[$0].gap.high.isFinite }
        let byGap = Dictionary(grouping: bounded) {
            Key(vertical: runs[$0].vertical, low: quantize(runs[$0].gap.low), high: quantize(runs[$0].gap.high))
        }
        var pairs: [(Int, Int)] = []
        for key in byGap.keys.sorted(by: { ($0.low, $0.high) < ($1.low, $1.high) }) {
            let members = byGap[key, default: []].sorted { runs[$0].low < runs[$1].low }
            // Sweep by extent: each run joins the run reaching furthest among those it overlaps.
            var reaching: Int?
            for m in members {
                if let r = reaching, runs[r].high - runs[m].low > tolerance { pairs.append((r, m)) }
                if reaching.map({ runs[m].high > runs[$0].high }) ?? true { reaching = m }
            }
        }
        return pairs
    }

    /// Runs by axis, sorted across it, so a corridor can find the runs outside it that bound its tracks.
    private struct Neighbours {
        private let order: [[Int]]
        private let positions: [[Float]]

        init(_ runs: [Run]) {
            let order = [false, true].map { vertical in
                runs.indices.filter { runs[$0].vertical == vertical }.sorted { runs[$0].at < runs[$1].at }
            }
            self.order = order
            positions = order.map { $0.map { runs[$0].at } }
        }

        /// Runs on `run`'s axis within `distance` across it.
        func near(_ run: Run, within distance: Float, _ body: (Int) -> Void) {
            let axis = run.vertical ? 1 : 0
            let list = positions[axis]
            var low = 0
            var high = list.count
            while low < high {
                let middle = (low + high) / 2
                if list[middle] < run.at - distance { low = middle + 1 } else { high = middle }
            }
            var i = low
            while i < list.count, list[i] <= run.at + distance {
                body(order[axis][i])
                i += 1
            }
        }
    }

    // MARK: - Placement

    /// Track positions for one corridor, or nil when it has no room for tracks a point apart.
    private func place(_ members: [Int], _ runs: [Run], _ neighbours: Neighbours) -> [Int: Float]? {
        let segments = members.map { m in
            TrackSegment(
                id: m,
                source: runs[m].source,
                target: runs[m].target,
                sourceSide: runs[m].sourceSide,
                targetSide: runs[m].targetSide
            )
        }
        guard let allocation = try? TrackAllocation.solve(segments, clearance: spacing) else { return nil }
        guard allocation.count > 1 else { return Dictionary(uniqueKeysWithValues: members.map { ($0, runs[$0].at) }) }
        let centre = members.map { runs[$0].at }.reduce(0, +) / Float(members.count)
        // A run outside the corridor alongside one inside it keeps its place; the corridor's track stays on its own
        // side of the midpoint between them, so neither corridor can move into the other.
        let inside = Set(members)
        let fences = members.map { m -> (low: Float, high: Float) in
            let run = runs[m]
            var fence = (low: -Float.infinity, high: Float.infinity)
            let reach = min(max(run.gap.high - run.gap.low, 0), 16 * spacing)
            neighbours.near(run, within: reach.isFinite ? reach : 16 * spacing) { q in
                let other = runs[q]
                // Only a run that overlaps this one along the line is alongside it; one meeting it end to end, such
                // as a port stub leading into the corridor, leaves the corridor its width.
                guard !inside.contains(q), abs(other.at - run.at) > Self.tolerance,
                    min(run.high, other.high) - max(run.low, other.low) > Self.tolerance
                else {
                    return
                }
                let middle = (run.at + other.at) / 2
                if other.at > run.at { fence.high = min(fence.high, middle) } else { fence.low = max(fence.low, middle) }
            }
            return fence
        }
        /// Where each run's track may go: `clearance` from nodes when `keepsClearance`, otherwise `step`.
        func bounds(step: Float, keepsClearance: Bool) -> [(low: Float, high: Float)] {
            let margin = keepsClearance ? clearance : step
            return members.indices.map { i in
                let run = runs[members[i]]
                var low = run.gap.low + margin
                var high = run.gap.high - margin
                if let face = run.face {
                    let inset = keepsClearance ? face.inset : min(face.inset, step)
                    low = max(low, face.low + inset)
                    high = min(high, face.high - inset)
                }
                return (max(low, fences[i].low + step / 2), min(high, fences[i].high - step / 2))
            }
        }
        /// Positions for tracks in `slots` order, as near the block centred on the routes as the bounds allow, or nil
        /// when they cannot all hold. Runs within `spacing` of each other along the line keep their order `step`
        /// apart; others may share a position.
        func positions(_ slots: [Int]) -> [Float]? {
            var successors = Array(repeating: [Int](), count: members.count)
            var predecessors = successors
            for i in members.indices {
                for j in members.indices where slots[i] < slots[j] {
                    let a = runs[members[i]]
                    let b = runs[members[j]]
                    guard min(a.high, b.high) - max(a.low, b.low) > -spacing else { continue }
                    successors[i].append(j)
                    predecessors[j].append(i)
                }
            }
            let order = members.indices.sorted { slots[$0] == slots[$1] ? $0 < $1 : slots[$0] < slots[$1] }
            let ranks = Dictionary(zip(Set(slots).sorted(), 0...), uniquingKeysWith: { a, _ in a })
            let count = Float(ranks.count)
            func place(step: Float, keepsClearance: Bool) -> [Float]? {
                let bounds = bounds(step: step, keepsClearance: keepsClearance)
                let first = centre - (count - 1) * step / 2
                var p = members.indices.map { i in
                    min(max(first + Float(ranks[slots[i], default: 0]) * step, bounds[i].low), bounds[i].high)
                }
                for i in order { for k in predecessors[i] { p[i] = max(p[i], p[k] + step) } }
                for i in order.reversed() {
                    p[i] = min(p[i], bounds[i].high)
                    for k in successors[i] { p[i] = min(p[i], p[k] - step) }
                }
                for i in order {
                    guard p[i].isFinite, p[i] >= bounds[i].low - Self.tolerance,
                        p[i] <= bounds[i].high + Self.tolerance
                    else { return nil }
                    for k in predecessors[i] where p[i] - p[k] < step - Self.tolerance { return nil }
                }
                return p
            }
            if let p = place(step: spacing, keepsClearance: true) { return p }
            // Short of room: the widest step that fits, keeping the clearance if that does as well as giving it up.
            var best: (step: Float, p: [Float])?
            for keepsClearance in [true, false] {
                var low: Float = 1
                var high = spacing
                guard var found = place(step: low, keepsClearance: keepsClearance) else { continue }
                for _ in 0..<10 {
                    let middle = (low + high) / 2
                    if let p = place(step: middle, keepsClearance: keepsClearance) {
                        low = middle
                        found = p
                    } else {
                        high = middle
                    }
                }
                if low > (best?.step ?? 0) + Self.tolerance { best = (low, found) }
            }
            return best?.p
        }
        let slots = members.map { allocation.slots[$0] ?? 0 }
        // Faces and fences can rule out the allocation's order; then the runs keep the order their room allows.
        let fallback: () -> [Int] = {
            let room = bounds(step: 1, keepsClearance: false)
            let key = members.indices.map { i in min(max(runs[members[i]].at, room[i].low), room[i].high) }
            let sorted = members.indices.sorted { key[$0] == key[$1] ? slots[$0] < slots[$1] : key[$0] < key[$1] }
            var rank = Array(repeating: 0, count: members.count)
            for (r, i) in sorted.enumerated() { rank[i] = r }
            return rank
        }
        guard let p = positions(slots) ?? positions(fallback()) else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(members, p).map { ($0, $1) })
    }

    // MARK: - Geometry

    private static func isOrthogonal(_ path: [Point]) -> Bool {
        zip(path, path.dropFirst()).allSatisfy { abs($0.x - $1.x) <= tolerance || abs($0.y - $1.y) <= tolerance }
    }

    /// Without repeated points and straight-through bends, so each stretch is one maximal run.
    private static func simplified(_ path: [Point]) -> [Point] {
        var result: [Point] = []
        for p in path {
            if let last = result.last, abs(p.x - last.x) <= tolerance, abs(p.y - last.y) <= tolerance { continue }
            if result.count >= 2 {
                let a = result[result.count - 2]
                let b = result[result.count - 1]
                let sameX = abs(a.x - b.x) <= tolerance && abs(b.x - p.x) <= tolerance
                let sameY = abs(a.y - b.y) <= tolerance && abs(b.y - p.y) <= tolerance
                if sameX || sameY {
                    result[result.count - 1] = p
                    continue
                }
            }
            result.append(p)
        }
        return result
    }

    private static func properCrossing(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        func side(_ p: Point, _ q: Point, _ r: Point) -> Float { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        return side(a, b, c) * side(a, b, d) < -1e-5 && side(c, d, a) * side(c, d, b) < -1e-5
    }

    private static func crossings(_ p: [Point], _ q: [Point]) -> Int {
        var count = 0
        for (a, b) in zip(p, p.dropFirst()) {
            for (c, d) in zip(q, q.dropFirst()) where properCrossing(a, b, c, d) { count += 1 }
        }
        return count
    }

    private static func selfCrossings(_ path: [Point]) -> Int {
        let segments = Array(zip(path, path.dropFirst()))
        var count = 0
        for i in segments.indices {
            for j in (i + 2)..<max(i + 2, segments.count)
            where properCrossing(segments[i].0, segments[i].1, segments[j].0, segments[j].1) {
                count += 1
            }
        }
        return count
    }
}
