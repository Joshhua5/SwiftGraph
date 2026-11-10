import Foundation

extension DirectedRouter {
    /// Refine the selected drawing with every other route present. The initial pass
    /// sees only earlier edges, so a valid hierarchy guide can retain avoidable jogs.
    /// Each accepted shortcut is obstacle-safe and cannot add crossings or length.
    func refine() throws {
        let ordered = edges.filter { !retained.contains($0) }
            .sorted {
                let a = $0.path.count
                let b = $1.path.count
                return a == b ? edgeIndices[required: $0] < edgeIndices[required: $1] : a > b
            }
        spacing = edgeSpacing
        for edge in ordered where edge.path.count > 4 {
            try Task.checkCancellation()
            load(excluding: edge)
            let others = nodes.filter { $0 !== edge.source && $0 !== edge.target }
                .map { $0.bounds.inflated(by: clearance) }
            func quality(_ path: [Point]) -> (crossings: Int, length: Float)? {
                var crossings = 0
                var length: Float = 0.0
                for segment in DirectedGeometry.segments(path) {
                    if !DirectedGeometry.clear(segment.a, segment.b, bodies: bodies)
                        || !DirectedGeometry.clear(segment.a, segment.b, bodies: others)
                    {
                        return nil
                    }
                    length += segment.length
                    var rejected = false
                    occupied.forEach(near: segment, margin: edgeSpacing) { _, other in
                        if DirectedGeometry.shared(segment, other)
                            || DirectedGeometry.nearShared(segment, other, spacing: edgeSpacing)
                        {
                            rejected = true
                        } else if DirectedGeometry.crossing(segment, other) != nil {
                            crossings += 1
                        }
                    }
                    if rejected { return nil }
                }
                return (crossings, length)
            }
            var path = edge.path
            guard var score = quality(path) else { continue }
            // Preserve the first and last segments, and therefore the port direction
            // and arrowhead approach. Bound work even for unusually winding inputs.
            for _ in 0..<2 {
                var changed = false
                let count = path.count
                guard count > 4 else { break }
                outer: for span in stride(from: min(count - 3, 10), through: 2, by: -1) {
                    for i in 1..<(count - 1 - span) {
                        let j = i + span
                        let a = path[i]
                        let b = path[j]
                        for elbow in [Point(x: a.x, y: b.y), Point(x: b.x, y: a.y)] {
                            let candidate = DirectedGeometry.compact(Array(path[...i]) + [elbow] + Array(path[j...]))
                            guard candidate.count < path.count, let next = quality(candidate),
                                next.crossings <= score.crossings, next.length <= score.length + 0.0001
                            else { continue }
                            path = candidate
                            score = next
                            changed = true
                            break outer
                        }
                    }
                }
                if !changed { break }
            }
            edge.path = path
        }
    }

    /// Bounded rip-up and reroute of the worst remaining paths. Unlike the initial
    /// pass, each trial sees every other route. Endpoint approaches stay fixed and
    /// acceptance is Pareto-monotone in crossings, bends and Manhattan length.
    func improveWorstRoutes() throws {
        coordinated = true
        spacing = edgeSpacing
        for _ in 0..<2 {
            var changed = false
            let worst = edges.filter { $0.path.count > 3 && !retained.contains($0) }
                .sorted {
                    if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
                    return edgeIndices[required: $0] < edgeIndices[required: $1]
                }
                .prefix(16)
            for edge in worst {
                try Task.checkCancellation()
                let original = edge.path
                load(excluding: edge)
                let nonEndpoints = nodes.filter { $0 !== edge.source && $0 !== edge.target }
                    .map { $0.bounds.inflated(by: clearance) }
                func quality(_ path: [Point]) -> (crossings: Int, bends: Int, length: Float)? {
                    let segments = DirectedGeometry.segments(path)
                    guard path.count >= 2,
                        segments.allSatisfy({
                            DirectedGeometry.clear($0.a, $0.b, bodies: bodies)
                                && DirectedGeometry.clear($0.a, $0.b, bodies: nonEndpoints)
                        })
                    else { return nil }
                    var hits: [Int: Set<Point>] = [:]
                    var rejected = false
                    for a in segments {
                        occupied.forEach(near: a, margin: edgeSpacing) { owner, b in
                            if DirectedGeometry.shared(a, b) || DirectedGeometry.nearShared(a, b, spacing: edgeSpacing)
                            {
                                rejected = true
                            } else if let p = DirectedGeometry.crossing(a, b) {
                                hits[owner, default: []].insert(p)
                            }
                        }
                        if rejected { return nil }
                    }
                    return (
                        hits.values.reduce(0) { $0 + $1.count }, max(0, path.count - 2),
                        segments.reduce(0) { $0 + $1.length }
                    )
                }
                guard var score = quality(original) else { continue }
                let start = original[0]
                // `original[0]` was read above and `original[1]` below, so the route is non-empty.
                let end = original.last!
                let u = original[1] - start
                let v = original[original.count - 2] - end
                let escape = start + u / u.length * min(clearance, u.length)
                let entry = end + v / v.length * min(clearance, v.length)
                var best = original
                func consider(_ middle: [Point]) {
                    guard
                        zip(middle, middle.dropFirst())
                            .allSatisfy({ DirectedGeometry.clear($0, $1, bodies: obstacles) })
                    else { return }
                    let candidate = DirectedGeometry.compact([start] + middle + [end])
                    guard let next = quality(candidate), next.crossings <= score.crossings, next.bends <= score.bends,
                        next.length <= score.length + DirectedGeometry.epsilon,
                        next.crossings < score.crossings || next.bends < score.bends
                            || next.length < score.length - DirectedGeometry.epsilon
                    else { return }
                    best = candidate
                    score = next
                }
                let xs = Array(Set(original.map(\.x) + [(escape.x + entry.x) / 2])).sorted()
                let ys = Array(
                    Set(original.map(\.y) + [(escape.y + entry.y) / 2] + exteriorLanes(from: escape, to: entry))
                )
                .sorted()
                for x in xs { consider([escape, Point(x: x, y: escape.y), Point(x: x, y: entry.y), entry]) }
                for y in ys { consider([escape, Point(x: escape.x, y: y), Point(x: entry.x, y: y), entry]) }
                if best == original,
                    let repaired = try search(
                        from: escape,
                        to: entry,
                        startAxis: axis(u),
                        endAxis: axis(v),
                        visitLimit: 4096
                    )
                {
                    consider(repaired)
                }
                if best != original {
                    edge.path = best
                    changed = true
                }
            }
            if !changed { break }
        }
    }

    /// Final tidying of the finished routes: near-miss edges straight, tiny jogs gone.
    func polish() throws {
        spacing = edgeSpacing
        try straightenDoglegs()
        try removeMicroJogs()
    }

    /// Crossings of `path` with the loaded routes, or nil when it hits a body, shares a run or crowds one.
    private func crossingCount(_ path: [Point], others: [Rect], spacing: Float? = nil) -> Int? {
        let gap = spacing ?? edgeSpacing
        var count = 0
        for segment in DirectedGeometry.segments(path) {
            guard DirectedGeometry.clear(segment.a, segment.b, bodies: bodies),
                DirectedGeometry.clear(segment.a, segment.b, bodies: others)
            else { return nil }
            var rejected = false
            occupied.forEach(near: segment, margin: gap) { _, other in
                if DirectedGeometry.shared(segment, other) || DirectedGeometry.nearShared(segment, other, spacing: gap)
                {
                    rejected = true
                } else if DirectedGeometry.crossing(segment, other) != nil {
                    count += 1
                }
            }
            if rejected { return nil }
        }
        return count
    }

    /// An interior jog shorter than `microLength` is removed by moving one of its two neighbouring runs onto the
    /// other's coordinate (the end runs hold the ports, so they stay). The move must keep the route clear and add no
    /// crossing.
    func removeMicroJogs(microLength: Float = 4) throws {
        for edge in edges.sorted(by: { edgeIndices[required: $0] < edgeIndices[required: $1] })
        where !retained.contains(edge) && edge.path.count >= 5 {
            try Task.checkCancellation()
            var loaded = false
            var others: [Rect] = []
            var before = 0
            for _ in 0..<4 {
                let path = edge.path
                guard path.count >= 5,
                    let k = (1..<(path.count - 2))
                        .first(where: {
                            (path[$0 + 1] - path[$0]).length < microLength
                                && (path[$0 + 1] - path[$0]).length > DirectedGeometry.epsilon
                        })
                else { break }
                if !loaded {
                    load(excluding: edge)
                    loaded = true
                    others = nodes.filter { $0 !== edge.source && $0 !== edge.target }
                        .map { $0.bounds.inflated(by: clearance) }
                    guard let count = crossingCount(path, others: others) else { break }
                    before = count
                }
                let vertical = abs(path[k].x - path[k + 1].x) < DirectedGeometry.epsilon
                var changed = false
                let candidates = [k + 1, k]
                    .sorted { a, b in
                        let fa = a == k + 1 ? k + 1 : k - 1
                        let fb = b == k + 1 ? k + 1 : k - 1
                        let ia = fa >= 1 && fa + 1 <= path.count - 2
                        let ib = fb >= 1 && fb + 1 <= path.count - 2
                        return ia && !ib
                    }
                for candidate in candidates {
                    // Moves the run that starts (after) or ends (before) at the jog onto the jog's far coordinate.
                    let first = candidate == k + 1 ? k + 1 : k - 1
                    let second = first + 1
                    let target = candidate == k + 1 ? path[k] : path[k + 1]
                    let isPortSlide = first < 1 || second > path.count - 2
                    let gap = isPortSlide ? min(edgeSpacing, 8) : edgeSpacing
                    if isPortSlide {
                        guard vertical, first == 0 || second == path.count - 1 else { continue }
                        let atStart = first == 0
                        let node = atStart ? edge.source : edge.target
                        let port = path[atStart ? 0 : path.count - 1]
                        guard let span = slideInterval(edge, node: node, at: port, margin: 6, spacing: gap),
                            target.y >= span.lo - DirectedGeometry.epsilon,
                            target.y <= span.hi + DirectedGeometry.epsilon
                        else { continue }
                    }
                    var next = path
                    for i in [first, second] { if vertical { next[i].y = target.y } else { next[i].x = target.x } }
                    next = DirectedGeometry.compact(next)
                    guard let count = crossingCount(next, others: others, spacing: gap), count <= before,
                        next.count < path.count
                    else { continue }
                    edge.path = next
                    before = count
                    changed = true
                    if var p = ports[edge] {
                        p.0 = next[0]
                        p.1 = next[next.count - 1]
                        ports[edge] = p
                    }
                    break
                }
                if !changed { break }
            }
        }
    }

    /// The free span along `node`'s `side` around the port at `point`: bounded by the side and the neighbouring
    /// ports (their order, and so the crossings they were assigned for, is kept).
    private func slideInterval(
        _ edge: LayoutEdge,
        node: LayoutNode,
        at point: Point,
        margin: Float = 8,
        spacing: Float? = nil
    ) -> (lo: Float, hi: Float)? {
        let gap = spacing ?? edgeSpacing
        let side: PortConstraint = abs(point.x - node.bounds.left) < 0.001 ? .left : .right
        guard Self.onSide(point, side, of: node.bounds, margin: 0) else { return nil }
        var (lo, hi) =
            node.bounds.height > 2 * margin
            ? (node.bounds.top + margin, node.bounds.bottom - margin) : (node.bounds.center.y, node.bounds.center.y)
        for other in edges where other !== edge {
            for (end, owner) in [(other.path.first, other.source), (other.path.last, other.target)] where owner === node
            {
                guard let end, Self.onSide(end, side, of: node.bounds, margin: 0) else { continue }
                if end.y < point.y { lo = max(lo, end.y + gap) } else { hi = min(hi, end.y - gap) }
            }
        }
        return (lo, hi)
    }

    /// A Z-shaped route between two left/right ports is straightened by sliding its ports along their sides to
    /// a common coordinate (as close to where they are as the neighbouring ports allow, each end moving only
    /// as far as needed). The straight run must be clear and add no crossing, sharing or crowding.
    func straightenDoglegs() throws {
        let order = edges.filter { !retained.contains($0) && $0.path.count == 4 && $0.source !== $0.target }
            .sorted { edgeIndices[required: $0] < edgeIndices[required: $1] }
        for edge in order {
            try Task.checkCancellation()
            let path = edge.path
            guard path.count == 4, abs(path[0].y - path[1].y) < DirectedGeometry.epsilon,
                abs(path[2].y - path[3].y) < DirectedGeometry.epsilon,
                abs(path[0].y - path[3].y) > DirectedGeometry.epsilon,
                let s = slideInterval(edge, node: edge.source, at: path[0]),
                let t = slideInterval(edge, node: edge.target, at: path[3])
            else { continue }
            let lo = max(s.lo, t.lo)
            let hi = min(s.hi, t.hi)
            guard lo <= hi + DirectedGeometry.epsilon else { continue }
            load(excluding: edge)
            let others = nodes.filter { $0 !== edge.source && $0 !== edge.target }
                .map { $0.bounds.inflated(by: clearance) }
            guard let before = crossingCount(path, others: others) else { continue }
            // The coordinate nearest the source end (then the target end) that both sides allow.
            let y = min(max(path[0].y, lo), hi)
            let next = [Point(x: path[0].x, y: y), Point(x: path[3].x, y: y)]
            guard let after = crossingCount(next, others: others), after <= before else { continue }
            edge.path = next
            if var p = ports[edge] {
                p.0 = next[0]
                p.1 = next[1]
                ports[edge] = p
            }
        }
    }

    /// Greedy routing leaves the occasional pair of runs closer than `edgeSpacing`. Each such
    /// route has its interior runs nudged to exactly the spacing from their neighbours; a nudge
    /// is kept only if it removes proximity without adding crossings or more than two bends.
    func separateProximateRuns() throws {
        spacing = edgeSpacing
        for _ in 0..<3 {
            load(excluding: nil)
            let troubled =
                edges.filter { edge in
                    guard !retained.contains(edge), edge.path.count > 3 else { return false }
                    let owner = edgeIndices[required: edge]
                    var near = false
                    for segment in DirectedGeometry.segments(edge.path) {
                        occupied.forEach(near: segment, margin: edgeSpacing) { other, b in
                            if other != owner && !DirectedGeometry.shared(segment, b)
                                && DirectedGeometry.nearShared(segment, b, spacing: edgeSpacing)
                            {
                                near = true
                            }
                        }
                    }
                    return near
                }
                .sorted { edgeIndices[required: $0] < edgeIndices[required: $1] }
            if troubled.isEmpty { return }
            var changed = false
            for edge in troubled {
                try Task.checkCancellation()
                load(excluding: edge)
                let others = nodes.filter { $0 !== edge.source && $0 !== edge.target }
                    .map { $0.bounds.inflated(by: clearance) }
                func quality(_ path: [Point]) -> (proximity: Int, crossings: Int, bends: Int)? {
                    var near: Set<Int> = []
                    var hits: [Int: Set<Point>] = [:]
                    var rejected = false
                    for segment in DirectedGeometry.segments(path) {
                        guard DirectedGeometry.clear(segment.a, segment.b, bodies: bodies),
                            DirectedGeometry.clear(segment.a, segment.b, bodies: others)
                        else { return nil }
                        occupied.forEach(near: segment, margin: edgeSpacing) { owner, b in
                            if DirectedGeometry.shared(segment, b) {
                                rejected = true
                            } else if DirectedGeometry.nearShared(segment, b, spacing: edgeSpacing) {
                                near.insert(owner)
                            } else if let p = DirectedGeometry.crossing(segment, b) {
                                hits[owner, default: []].insert(p)
                            }
                        }
                        if rejected { return nil }
                    }
                    return (near.count, hits.values.reduce(0) { $0 + $1.count }, max(0, path.count - 2))
                }
                var path = edge.path
                guard var score = quality(path) else { continue }
                for _ in 0..<4 where score.proximity > 0 {
                    var best: ([Point], (proximity: Int, crossings: Int, bends: Int))?
                    for k in 1..<(path.count - 2) {
                        let a = path[k]
                        let b = path[k + 1]
                        let horizontal = abs(a.y - b.y) < DirectedGeometry.epsilon
                        guard horizontal || abs(a.x - b.x) < DirectedGeometry.epsilon else { continue }
                        var targets: Set<Float> = []
                        occupied.forEach(near: DirectedGeometry.Segment(a: a, b: b), margin: edgeSpacing) { _, other in
                            guard other.horizontal == horizontal else { return }
                            let c = horizontal ? other.a.y : other.a.x
                            targets.insert(c - edgeSpacing)
                            targets.insert(c + edgeSpacing)
                        }
                        for c in targets.sorted() {
                            var candidate = path
                            if horizontal {
                                candidate[k].y = c
                                candidate[k + 1].y = c
                            } else {
                                candidate[k].x = c
                                candidate[k + 1].x = c
                            }
                            candidate = DirectedGeometry.compact(candidate)
                            guard let next = quality(candidate), next.proximity < score.proximity,
                                next.crossings <= score.crossings,
                                next.bends <= score.bends + 2
                            else { continue }
                            // `best!` is only evaluated after `best == nil` is false.
                            if best == nil
                                || (next.proximity, next.crossings, next.bends) < (
                                    best!.1.proximity, best!.1.crossings, best!.1.bends
                                )
                            {
                                best = (candidate, next)
                            }
                        }
                    }
                    guard let best else { break }
                    path = best.0
                    score = best.1
                }
                if path != edge.path {
                    edge.path = path
                    changed = true
                }
            }
            if !changed { return }
        }
    }
}
