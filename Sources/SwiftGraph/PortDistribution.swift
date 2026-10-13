import Foundation

/// Spreads the endpoints that meet a node side over evenly spaced slots, ordered by where each edge goes next so
/// neighbouring edges do not cross at the node. Run it after `EdgeEndpointClipper`: only endpoints on a node's
/// boundary are moved. Orthogonal routes slide their first or last leg (adding a jog when the route is a single
/// straight leg); other routes just move the endpoint. An edge is left alone when the change would touch a node or
/// cross a route it did not cross before, and a side too small for `edgeSpacing` between its ends is left as it is.
public final class PortDistributor: EdgeRouter {
    /// Distance kept from the corners of a side.
    public var margin: Double = 6
    /// How far from a side an endpoint may sit and still count as attached to it (channel ports sit 1 unit out).
    public var tolerance: Double = 1.5
    /// Least gap between neighbouring ends on a side; ends already this far apart are left where they are.
    public var edgeSpacing: Double = 10
    public init() {}

    private struct Key: Hashable { var node: LayoutNode; var side: PortConstraint }
    private struct End { var edge: LayoutEdge; var start: Bool; var along: Double; var key: Double; var order: Int }

    public func routeEdges(_ graph: LayoutGraph) {
        var groups: [Key: [End]] = [:], keys: [Key] = []
        // Legs are only slid or jogged in orthogonal drawings; axis-aligned edges of a polyline drawing just tilt.
        let axisAligned = { (e: LayoutEdge) in zip(e.path, e.path.dropFirst()).allSatisfy { abs($0.x - $1.x) < 1e-9 || abs($0.y - $1.y) < 1e-9 } }
        let routed = graph.edges.filter { $0.source !== $0.target && $0.path.count >= 2 }
        let orthogonal = routed.allSatisfy(axisAligned) && routed.contains { $0.path.count >= 3 }
        for (order, e) in graph.edges.enumerated() where e.source !== e.target && e.path.count >= 2 {
            for start in [true, false] {
                let node = start ? e.source : e.target, path = start ? e.path : e.path.reversed()
                guard let side = side(of: path, node.bounds, constraint: start ? e.sourcePort : e.targetPort) else { continue }
                let p = path[0], k = Key(node: node, side: side)
                if groups[k] == nil { keys.append(k) }
                let along = Self.along(p, side), next = path.dropFirst().first { abs(Self.along($0, side) - along) > 1e-6 }
                groups[k, default: []].append(End(edge: e, start: start, along: along, key: next.map { Self.along($0, side) } ?? along, order: order))
            }
        }
        var scene = Crossings(routed)
        for k in keys {
            if RoutingCompute.isCancelled { return }
            let r = k.node.bounds, horizontal = k.side == .top || k.side == .bottom
            let low = horizontal ? r.left : r.top, high = horizontal ? r.right : r.bottom
            guard high - low > 2 * margin else { continue }
            // Where the routes already lie decides the order, the next bend only breaking ties between coincident ends; where
            // that order would leave more crossings than the bend order does, the bend order is used.
            let all = groups[k]!
            let orders = [all.sorted { ($0.along.rounded(), $0.key, $0.order, $0.start ? 0 : 1) < ($1.along.rounded(), $1.key, $1.order, $1.start ? 0 : 1) },
                          all.sorted { ($0.key, $0.along, $0.order, $0.start ? 0 : 1) < ($1.key, $1.along, $1.order, $1.start ? 0 : 1) }]
            let plans = orders.indices.filter { $0 == 0 || orders[$0].map(\.order) != orders[0].map(\.order) || orders[$0].map(\.start) != orders[0].map(\.start) }.compactMap { o -> [Move]? in
                let ends = orders[o]
                guard let slots = slots(ends.map(\.along), low: low, high: high) else { return nil }
                let moves = ends.enumerated().compactMap { i, end -> Move? in
                    candidate(end.edge, start: end.start, side: k.side, to: slots[i], orthogonal: orthogonal, jog: Double(i + 1) / Double(ends.count + 1), graph)
                        .map { Move(edge: end.edge, old: end.edge.path, new: $0, before: scene.count(of: end.edge)) }
                }
                return moves.isEmpty ? nil : moves
            }
            guard !plans.isEmpty else { continue }
            var seen = Set<LayoutEdge>()
            let touched = plans.flatMap { $0.map(\.edge) }.filter { seen.insert($0).inserted }, was = scene.total(touched)
            func apply(_ moves: [Move]) { for m in moves { m.edge.path = m.new; scene.update(m.edge) } }
            func undo(_ m: Move) { m.edge.path = m.old; scene.update(m.edge) }
            let scored = plans.map { plan -> Crossings.Count in apply(plan); defer { plan.forEach(undo) }; return scene.total(touched) }
            var best = 0
            for i in scored.indices.dropFirst() where (scored[i].pair, scored[i].all) < (scored[best].pair, scored[best].all) { best = i }
            let chosen = plans[best]
            apply(chosen)
            // The moves must not leave more crossings than they found, nor more between edges joining the same nodes:
            // while they do, the move that gained most crossings is undone.
            var kept = chosen
            while !kept.isEmpty {
                let now = scene.total(touched)
                if now.all <= was.all && now.pair <= was.pair { break }
                let worst = kept.indices.max { a, b in
                    let x = scene.count(of: kept[a].edge), y = scene.count(of: kept[b].edge)
                    return (x.all - kept[a].before.all, x.pair - kept[a].before.pair, -a) < (y.all - kept[b].before.all, y.pair - kept[b].before.pair, -b)
                }!
                undo(kept[worst]); kept.remove(at: worst)
            }
        }
    }
    private struct Move { var edge: LayoutEdge, old: [Point], new: [Point], before: Crossings.Count }

    /// Slot positions for a face's ends (in order), or nil to leave them. Ends at least a pitch apart stay where they are
    /// (corners aside); otherwise they are pushed apart as little as possible, evenly spaced when they coincide.
    private func slots(_ along: [Double], low: Double, high: Double) -> [Double]? {
        let n = along.count, lo = low + margin, hi = high - margin
        guard n > 1 else { return along.map { min(max($0, lo), hi) } }
        let even = (high - low) / Double(n + 1), fit = (hi - lo) / Double(n - 1), floor = min(edgeSpacing, even)
        // Crowded faces keep what they have rather than being crammed below the minimum lane spacing.
        guard fit >= floor - 1e-9 else { return nil }
        let held = along.map { min(max($0, lo), hi) }
        if zip(held, held.dropFirst()).allSatisfy({ $1 - $0 >= floor - 1e-9 }) { return held }
        // Least squares with gaps of at least `pitch`: pool adjacent violators on the positions less their rank offset.
        let pitch = min(even, fit)
        var blocks: [(sum: Double, count: Int)] = []
        for (i, a) in held.enumerated() {
            blocks.append((a - Double(i) * pitch, 1))
            while blocks.count > 1, blocks[blocks.count - 2].sum / Double(blocks[blocks.count - 2].count) > blocks[blocks.count - 1].sum / Double(blocks[blocks.count - 1].count) {
                let last = blocks.removeLast(); blocks[blocks.count - 1].sum += last.sum; blocks[blocks.count - 1].count += last.count
            }
        }
        let base = blocks.flatMap { b in Array(repeating: b.sum / Double(b.count), count: b.count) }
        return base.enumerated().map { i, y in min(max(y, lo), hi - Double(n - 1) * pitch) + Double(i) * pitch }
    }

    private static func along(_ p: Point, _ side: PortConstraint) -> Double { side == .top || side == .bottom ? p.x : p.y }
    private static func with(_ p: Point, _ side: PortConstraint, along value: Double) -> Point {
        side == .top || side == .bottom ? Point(x: value, y: p.y) : Point(x: p.x, y: value)
    }

    /// The side a route leaves its node by: the endpoint lies on it and the route heads away from the node.
    private func side(of path: [Point], _ r: Rect, constraint: PortConstraint) -> PortConstraint? {
        let p = path[0]
        guard let q = path.dropFirst().first(where: { ($0 - p).length > 1e-9 }) else { return nil }
        let d = q - p
        var best: (side: PortConstraint, outward: Double)?
        for (side, offset, within, outward) in [
            (PortConstraint.top, p.y - r.top, p.x >= r.left - tolerance && p.x <= r.right + tolerance, -d.y),
            (.bottom, p.y - r.bottom, p.x >= r.left - tolerance && p.x <= r.right + tolerance, d.y),
            (.left, p.x - r.left, p.y >= r.top - tolerance && p.y <= r.bottom + tolerance, -d.x),
            (.right, p.x - r.right, p.y >= r.top - tolerance && p.y <= r.bottom + tolerance, d.x)]
        where abs(offset) <= tolerance && within && outward > 1e-9 && (best == nil || outward > best!.outward + 1e-9) {
            best = (side, outward)
        }
        guard let found = best?.side, constraint == .none || constraint == found else { return nil }
        return found
    }

    private func candidate(_ e: LayoutEdge, start: Bool, side: PortConstraint, to slot: Double, orthogonal: Bool, jog: Double, _ graph: LayoutGraph) -> [Point]? {
        let p = start ? e.path : Array(e.path.reversed()), here = Self.along(p[0], side)
        guard abs(slot - here) > 1e-9 else { return nil }
        var q = p
        q[0] = Self.with(p[0], side, along: slot)
        if orthogonal && abs(Self.along(p[1], side) - here) < 1e-9 {
            if p.count > 2 { q[1] = Self.with(p[1], side, along: slot) }
            else {
                // A single straight leg: step sideways part way along it, at a height unique to the slot.
                let horizontal = side == .top || side == .bottom
                let mid = horizontal ? p[0].y + (p[1].y - p[0].y) * jog : p[0].x + (p[1].x - p[0].x) * jog
                let a = horizontal ? Point(x: slot, y: mid) : Point(x: mid, y: slot), b = horizontal ? Point(x: here, y: mid) : Point(x: mid, y: here)
                q = [q[0], a, b, p[1]]
            }
        }
        q = compactPath(q)
        // Only the legs near the moved end change; they must stay off every other node and out of the edge's own.
        let blocks = ObstaclePolyline.obstacles(e, graph) + [e.source, e.target].map { $0.bounds.inflated(by: -1e-6) }.filter { $0.width > 0 && $0.height > 0 }
        guard q.count >= 2, ObstaclePolyline.clear(Array(q.prefix(4)), blocks) else { return nil }
        return start ? q : Array(q.reversed())
    }

    /// Every routed edge's route with a bounding box, to count the crossings a change makes near some edges.
    private struct Crossings {
        struct Count { var all = 0, pair = 0 }
        let edges: [LayoutEdge]
        private var boxes: [Rect]
        private let index: [ObjectIdentifier: Int]
        init(_ edges: [LayoutEdge]) {
            self.edges = edges; boxes = edges.map { ObstaclePolyline.bounds($0.path) }
            index = Dictionary(uniqueKeysWithValues: edges.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
        }
        mutating func update(_ e: LayoutEdge) { if let i = index[ObjectIdentifier(e)] { boxes[i] = ObstaclePolyline.bounds(e.path) } }
        private static func crosses(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
            func x(_ p: Point, _ q: Point) -> Double { p.x * q.y - p.y * q.x }
            let u = b - a, v = d - c, den = x(u, v)
            guard abs(den) > 1e-12 else { return false }
            let t = x(c - a, v) / den, s = x(c - a, u) / den
            return t > 1e-9 && t < 1 - 1e-9 && s > 1e-9 && s < 1 - 1e-9
        }
        /// Crossings of an edge's route with the other routes, and of those with edges joining the same two nodes.
        func count(of e: LayoutEdge, ignoring skip: Set<Int> = []) -> Count {
            guard let me = index[ObjectIdentifier(e)] else { return Count() }
            let area = boxes[me].inflated(by: 1e-6), legs = Array(zip(e.path, e.path.dropFirst()))
            var result = Count()
            for j in edges.indices where j != me && !skip.contains(j) {
                let b = boxes[j]
                guard b.left <= area.right && b.right >= area.left && b.top <= area.bottom && b.bottom >= area.top else { continue }
                var n = 0
                for (c, d) in zip(edges[j].path, edges[j].path.dropFirst()) { for (a, b) in legs where Self.crosses(a, b, c, d) { n += 1 } }
                result.all += n
                if (edges[j].source === e.source && edges[j].target === e.target) || (edges[j].source === e.target && edges[j].target === e.source) { result.pair += n }
            }
            return result
        }
        /// Crossings of the given edges with every other route, those between two of them counted once.
        func total(_ list: [LayoutEdge]) -> Count {
            var seen = Set<Int>(), result = Count()
            for e in list {
                let c = count(of: e, ignoring: seen)
                result.all += c.all; result.pair += c.pair
                if let i = index[ObjectIdentifier(e)] { seen.insert(i) }
            }
            return result
        }
    }
}
