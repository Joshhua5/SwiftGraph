import Foundation

func portPoint(_ node: LayoutNode, side: PortConstraint) -> Point {
    let r = node.bounds
    switch side {
    case .top: return Point(x: r.center.x, y: r.top)
    case .bottom: return Point(x: r.center.x, y: r.bottom)
    case .left: return Point(x: r.left, y: r.center.y)
    case .right: return Point(x: r.right, y: r.center.y)
    case .none: return r.center
    }
}
func portDirection(_ side: PortConstraint) -> Point {
    switch side {
    case .top: Point(x: 0, y: -1)
    case .bottom: Point(x: 0, y: 1)
    case .left: Point(x: -1, y: 0)
    case .right: Point(x: 1, y: 0)
    case .none: .zero
    }
}
func isAncestor(_ ancestor: LayoutNode, of node: LayoutNode) -> Bool {
    var current = node.parent, seen = Set<LayoutNode>()
    while let parent = current, seen.insert(parent).inserted {
        if parent === ancestor { return true }; current = parent.parent
    }
    return false
}
func compactPath(_ path: [Point]) -> [Point] {
    var result: [Point] = []
    for p in path {
        if result.last == p { continue }
        if result.count >= 2 {
            let a = result[result.count - 2], b = result[result.count - 1], u = b - a, v = p - b
            if abs(u.x * v.y - u.y * v.x) < 1e-8 && u.x * v.x + u.y * v.y >= 0 { result.removeLast() }
        }
        result.append(p)
    }
    return result
}
public enum EdgeEndpointClipper {
    /// Trims each route to the last exit from its source and the first entry into its target. Routes that
    /// would be left with fewer than two points stay as they were.
    public static func clipToNodeBounds(_ graph: LayoutGraph) {
        for edge in graph.edges where edge.source !== edge.target && edge.path.count >= 2 {
            let start = clipStart(edge.path, to: edge.source.bounds)
            edge.path = Array(clipStart(Array(start.reversed()), to: edge.target.bounds).reversed())
        }
    }
    private static func clipStart(_ path: [Point], to rect: Rect) -> [Point] {
        let inside = (RoutingCompute.current.flatMap { $0.stages.isEmpty || path.count >= 64 ? $0.contains(path, rect) : nil }) ?? path.map(rect.contains)
        guard inside.first == true, inside.last == false else { return path }
        let core = rect.inflated(by: -1e-6)
        for k in stride(from: path.count - 2, through: 0, by: -1) {
            let a = path[k], b = path[k + 1]
            // A segment may cross the node without a vertex inside it; grazing the boundary does not count.
            guard inside[k] || (core.width > 0 && core.height > 0 && core.intersectsLine(a, b)), let t = exit(a, b, rect) else { continue }
            let point = a + (b - a) * t
            var rest = Array(path[(k + 1)...])
            // A sample hugging the boundary would leave a micro-segment; absorb it unless it is a real bend.
            if rest.count > 1, (rest[0] - point).length < 4, Self.shallow(point, rest[0], rest[1]) { rest.removeFirst() }
            let clipped = compactPath([point] + rest)
            return clipped.count >= 2 ? clipped : path
        }
        return path
    }
    private static func shallow(_ a: Point, _ b: Point, _ c: Point) -> Bool {
        let u = b - a, v = c - b, lu = u.length, lv = v.length
        return lu > 1e-12 && lv > 1e-12 && (u.x * v.x + u.y * v.y) / (lu * lv) > 0.9
    }
    /// Parameter at which segment `a`→`b` leaves `rect`, or nil when it misses it.
    private static func exit(_ a: Point, _ b: Point, _ rect: Rect) -> Double? {
        var lo = 0.0, hi = 1.0
        for (origin, delta, low, high) in [(a.x, b.x - a.x, rect.left, rect.right), (a.y, b.y - a.y, rect.top, rect.bottom)] {
            if abs(delta) < 1e-12 {
                if origin < low || origin > high { return nil }
            } else {
                let t1 = (low - origin) / delta, t2 = (high - origin) / delta
                lo = max(lo, min(t1, t2)); hi = min(hi, max(t1, t2))
                if lo > hi { return nil }
            }
        }
        return max(0, hi)
    }
}

/// Routes self-loops as compact orthogonal corner loops: out of one side near a corner, `loopSize` round the
/// corner and back into the adjacent side. Each loop takes the corner that is clear of other nodes, crosses the
/// fewest routes and is furthest from where incident edges attach; further loops on a node take other corners,
/// then nest outward.
public final class SelfLoopRouter: EdgeRouter {
    /// How far a corner loop reaches beyond the node.
    public var loopSize: Double = 16
    /// Clearance a loop keeps from other nodes.
    public var padding: Double = 4
    /// Loops with no clear corner; they are still drawn at the best one.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        unroutableEdges = []
        let loops = graph.edges.filter { $0.source === $0.target }
        var pending = Set(loops), used: [LayoutNode: [Int]] = [:]
        let loopCounts = Dictionary(grouping: loops, by: \.source).mapValues(\.count)
        for edge in loops {
            let node = edge.source, r = node.bounds, corners = used[node, default: []]
            let ring = Double(corners.count / 4), taken = Set(corners.suffix(corners.count % 4))
            // Rings step outward by 6 along the sides; on small nodes the steps shrink to fit before the middle, so legs stay apart.
            let cap = max(2, min(r.width, r.height) / 2 - 1.5), base = min(max(min(r.width, r.height) / 4, 4), 16, cap)
            let rings = Double((loopCounts[node, default: 1] + 3) / 4)
            let inset = base + ring * (rings > 1 ? min(6, max(1, (cap - base) / (rings - 1))) : 6)
            let size = loopSize + ring * 6
            let obstacles = ObstaclePolyline.obstacles(edge, graph).map { $0.inflated(by: padding) }
            // Loops still to be routed carry stale paths; leave them out of the crossing count.
            let routes = graph.edges.filter { $0 !== edge && !pending.contains($0) && $0.path.count >= 2 }.map(\.path)
            let attached = Self.attachments(node, graph)
            var best: (path: [Point], corner: Int, score: [Double])?, fallback: (path: [Point], corner: Int, score: [Double])?
            for scale in [1.0, 0.5] where best == nil {
                for corner in 0..<4 where !taken.contains(corner) {
                    let path = Self.loop(r, corner: corner, size: size * scale, inset: inset)
                    let score = [Double(Self.overlaps(path, routes)), Double(Self.crossings(path, routes)), Double(attached[corner]), Double(corner)]
                    if ObstaclePolyline.clear(path, obstacles) {
                        if best == nil || score.lexicographicallyPrecedes(best!.score) { best = (path, corner, score) }
                    } else if scale == 1, fallback == nil || score.lexicographicallyPrecedes(fallback!.score) {
                        fallback = (path, corner, score)
                    }
                }
            }
            if best == nil { unroutableEdges.append(edge) }
            if let chosen = best ?? fallback { edge.path = chosen.path; used[node, default: []].append(chosen.corner) }
            pending.remove(edge)
        }
    }
    /// Corner 0 is top-right, then clockwise.
    private static func loop(_ r: Rect, corner: Int, size: Double, inset: Double) -> [Point] {
        let sx: Double = corner < 2 ? 1 : -1, sy: Double = corner == 0 || corner == 3 ? -1 : 1
        let cx = sx > 0 ? r.right : r.left, cy = sy < 0 ? r.top : r.bottom
        let a = min(inset, r.width / 2, r.height / 2)
        return [Point(x: cx - sx * a, y: cy), Point(x: cx - sx * a, y: cy + sy * size), Point(x: cx + sx * size, y: cy + sy * size),
                Point(x: cx + sx * size, y: cy - sy * a), Point(x: cx, y: cy - sy * a)]
    }
    /// How many incident edges leave the node towards each corner's quadrant.
    private static func attachments(_ node: LayoutNode, _ graph: LayoutGraph) -> [Int] {
        var counts = [0, 0, 0, 0]
        let c = node.center
        for e in graph.edges where e.source !== e.target && (e.source === node || e.target === node) && e.path.count >= 2 {
            let path = e.source === node ? e.path : e.path.reversed()
            // A route starting at the centre shows its direction at the next point.
            let p = (path[0] - c).length > 1e-9 ? path[0] : path[1]
            counts[p.x >= c.x ? (p.y < c.y ? 0 : 1) : (p.y < c.y ? 3 : 2)] += 1
        }
        return counts
    }
    /// Segment pairs that run along the same line over a stretch; stacked edges read as one.
    private static func overlaps(_ path: [Point], _ routes: [[Point]]) -> Int {
        func cross(_ a: Point, _ b: Point) -> Double { a.x * b.y - a.y * b.x }
        var count = 0
        for (a, b) in zip(path, path.dropFirst()) {
            let u = b - a, length = u.length
            guard length > 1e-9 else { continue }
            for route in routes {
                for (c, d) in zip(route, route.dropFirst()) where abs(cross(u, c - a)) < 1e-6 * length && abs(cross(u, d - a)) < 1e-6 * length {
                    let s = (c - a).x * u.x + (c - a).y * u.y, e = (d - a).x * u.x + (d - a).y * u.y
                    if min(length * length, max(s, e)) - max(0, min(s, e)) > 1e-6 * length { count += 1 }
                }
            }
        }
        return count
    }
    private static func crossings(_ path: [Point], _ routes: [[Point]]) -> Int {
        func cross(_ a: Point, _ b: Point) -> Double { a.x * b.y - a.y * b.x }
        var count = 0
        let segments = Array(zip(path, path.dropFirst())), other = routes.flatMap { Array(zip($0, $0.dropFirst())) }
        let flags = RoutingCompute.current?.candidates(segments.map { RoutingCompute.bounds($0.0, $0.1) }, other.map { RoutingCompute.bounds($0.0, $0.1) })
        for (i, segment) in segments.enumerated() {
            let (a, b) = segment
            for (j, pair) in other.enumerated() where flags == nil || flags![i * other.count + j] != 0 {
                let (c, d) = pair, u = b - a, v = d - c, denominator = cross(u, v)
                guard abs(denominator) > 1e-12 else { continue }
                let t = cross(c - a, v) / denominator, s = cross(c - a, u) / denominator
                if t > 1e-9 && t < 1 - 1e-9 && s > 1e-9 && s < 1 - 1e-9 { count += 1 }
            }
        }
        return count
    }
}
/// Replaces every segment of `path` that crosses an obstacle by a visibility detour; segments with no detour are kept.
func detourBlocked(_ path: [Point], _ obstacles: [Rect], padding: Double = 8) -> [Point] {
    var result = path, k = 0
    while k + 1 < result.count {
        if RoutingCompute.isCancelled { return result }
        let a = result[k], b = result[k + 1]
        if !ObstaclePolyline.clear([a, b], obstacles), let detour = ObstaclePolyline.search(a, b, obstacles, padding: padding), detour.count > 2 {
            result.replaceSubrange(k...(k + 1), with: detour); k += detour.count - 1
        } else { k += 1 }
    }
    return result
}
private func overlaps(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
    let u = b - a, v = d - c, length = u.length
    guard length > 1e-9, v.length > 1e-9 else { return false }
    let tolerance = 1e-6 * max(length, v.length)
    guard abs(u.x * v.y - u.y * v.x) < tolerance, abs(u.x * (c - a).y - u.y * (c - a).x) < tolerance else { return false }
    let tc = ((c - a).x * u.x + (c - a).y * u.y) / length, td = ((d - a).x * u.x + (d - a).y * u.y) / length
    return min(length, max(tc, td)) - max(0, min(tc, td)) > 1e-6
}
private func onSegment(_ p: Point, _ a: Point, _ b: Point) -> Bool {
    let u = b - a, w = p - a, length = u.length
    guard length > 1e-9, abs(u.x * w.y - u.y * w.x) < 1e-6 * length else { return false }
    let t = (w.x * u.x + w.y * u.y) / (length * length)
    return t > 1e-9 && t < 1 - 1e-9
}
/// Straight, or one 45-degree stretch and one axis-aligned stretch. Each edge takes the diagonal at its start or its end,
/// whichever avoids nodes, then siblings' shared stretches, then bends that sit on another route.
public final class OctilinearEdgeRouter: EdgeRouter {
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        let edges = graph.edges.filter { $0.source !== $0.target }
        let bends = RoutingCompute.current?.octilinear(edges.map { $0.source.center }, edges.map { $0.target.center })
        var routed: [(edge: LayoutEdge, path: [Point])] = []
        // Edges with a single possible route go first, so the ones with a choice can steer clear of them.
        func bendOf(_ e: LayoutEdge) -> Point? {
            let a = e.source.center, b = e.target.center, d = b - a, diagonal = min(abs(d.x), abs(d.y))
            let bend = a + Point(x: d.x >= 0 ? diagonal : -diagonal, y: d.y >= 0 ? diagonal : -diagonal)
            return (bend - a).length > 1 && (bend - b).length > 1 ? bend : nil
        }
        for e in edges where bendOf(e) == nil { e.path = [e.source.center, e.target.center]; routed.append((e, e.path)) }
        for (i, e) in edges.enumerated() {
            if RoutingCompute.isCancelled { return }
            let a = e.source.center, b = e.target.center
            guard let bend = bendOf(e) else { continue }
            let first = bends?[i] ?? bend, options = [[a, first, b], [a, b - (first - a), b]]
            let obstacles = ObstaclePolyline.obstacles(e, graph)
            let scores = options.enumerated().map { k, path -> [Double] in
                let segments = Array(zip(path, path.dropFirst()))
                let hits = obstacles.filter { r in segments.contains { r.intersectsLine($0.0, $0.1) } }.count
                var shared = 0, onRoute = 0
                for other in routed {
                    let sibling = other.edge.source === e.source || other.edge.target === e.source || other.edge.source === e.target || other.edge.target === e.target
                    for (c, f) in zip(other.path, other.path.dropFirst()) {
                        if sibling && segments.contains(where: { overlaps($0.0, $0.1, c, f) }) { shared += 1 }
                        if onSegment(path[1], c, f) { onRoute += 1 }
                    }
                }
                return [Double(hits), Double(shared), Double(onRoute), Double(k)]
            }
            let best = scores.indices.min { scores[$0].lexicographicallyPrecedes(scores[$1]) }!
            e.path = options[best]; routed.append((e, e.path))
        }
    }
}
/// Shifts the interior vertices of `path` sideways by `offset` (mitred, capped); the ends stay where they are.
private func offsetPolyline(_ path: [Point], by offset: Double) -> [Point] {
    guard path.count > 2 else { return path }
    func normal(_ a: Point, _ b: Point) -> Point { let d = b - a, l = max(1e-9, d.length); return Point(x: -d.y / l, y: d.x / l) }
    return path.indices.map { i in
        guard i > 0 && i < path.count - 1 else { return path[i] }
        let n1 = normal(path[i - 1], path[i]), n2 = normal(path[i], path[i + 1]), sum = n1 + n2, l = sum.length
        guard l > 1e-9 else { return path[i] }
        return path[i] + sum / l * (offset / max(0.5, l / 2))
    }
}
/// Edges between the same two nodes get lanes spread either side of the straight line. When a lane would cross a node
/// the group follows the shortest way round instead, with the lanes spread along it; a lone edge keeps its route.
public final class ParallelEdgeRouter: EdgeRouter {
    public var edgeSpacing: Double = 20
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        var groups: [Set<LayoutNode>: [LayoutEdge]] = [:]
        for e in graph.edges where e.source !== e.target { groups[[e.source, e.target], default: []].append(e) }
        for edges in groups.values {
            if RoutingCompute.isCancelled { return }
            guard edges.count > 1 else {
                if edges[0].path.count < 2 { edges[0].path = [edges[0].source.center, edges[0].target.center] }
                continue
            }
            let a = edges[0].source.center, b = edges[0].target.center, delta = b - a, length = max(0.001, delta.length)
            let normal = Point(x: -delta.y / length, y: delta.x / length)
            let offsets = edges.indices.map { (Double($0) - Double(edges.count - 1) / 2) * edgeSpacing }
            let midpoints = RoutingCompute.current?.parallel(Array(repeating: a, count: edges.count), Array(repeating: b, count: edges.count), offsets: offsets)
            let obstacles = ObstaclePolyline.obstacles(edges[0], graph)
            var base: [Point]??
            for (i, e) in edges.enumerated() {
                let forward = e.source === edges[0].source
                var path = [a, midpoints?[i] ?? ((a + b) / 2 + normal * offsets[i]), b]
                if !ObstaclePolyline.clear(path, obstacles) {
                    if base == nil { base = .some(ObstaclePolyline.search(a, b, obstacles, padding: 10 + (offsets.map(abs).max() ?? 0)).flatMap { $0.count > 2 ? $0 : nil }) }
                    if let around = base!, let free = [offsets[i], offsets[i] / 2, 0].map({ offsetPolyline(around, by: $0) }).first(where: { ObstaclePolyline.clear($0, obstacles) }) { path = free }
                }
                e.path = forward ? path : path.reversed()
            }
        }
    }
}
/// Hubs with three or more edges get a bus: each edge leaves the hub, runs along a lane in a gap beside the nodes and
/// turns into its leaf. Leaves are grouped by column (or row) and every group has its own parallel lane, so the shared
/// stretch shows which leaves belong together. Legs that would cross a node are detoured.
public final class BusEdgeRouter: EdgeRouter {
    public var busSpacing: Double = 20
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        var processed = Set<LayoutEdge>()
        for hub in graph.nodes {
            if RoutingCompute.isCancelled { return }
            let edges = graph.edges.filter { $0.source !== $0.target && ($0.source === hub || $0.target === hub) }
            guard edges.count >= 3 else { continue }
            let others = edges.map { $0.source === hub ? $0.target : $0.source }
            let horizontal = others.map(\.x).max()! - others.map(\.x).min()! > others.map(\.y).max()! - others.map(\.y).min()!
            let mean = others.reduce(Point.zero) { $0 + $1.center } / Double(others.count)
            // Lanes sit across the trunk axis: y for a horizontal bus, x for a vertical one.
            let side: Double = (horizontal ? mean.y >= hub.center.y : mean.x >= hub.center.x) ? 1 : -1
            func lane(_ r: Rect) -> ClosedRange<Double> { horizontal ? r.top...r.bottom : r.left...r.right }
            func along(_ r: Rect) -> ClosedRange<Double> { horizontal ? r.left...r.right : r.top...r.bottom }
            func point(_ lane: Double, _ along: Double) -> Point { horizontal ? Point(x: along, y: lane) : Point(x: lane, y: along) }
            let hubLane = lane(hub.bounds), reach = side > 0 ? hubLane.upperBound : hubLane.lowerBound
            let cross = others.map { horizontal ? $0.center.y : $0.center.x }
            let thickness = others.map { lane($0.bounds).upperBound - lane($0.bounds).lowerBound }
            var groups: [[Int]] = []
            for i in others.indices.sorted(by: { cross[$0] == cross[$1] ? $0 < $1 : cross[$0] < cross[$1] }) {
                if let last = groups.last?.last, cross[i] - cross[last] <= (thickness[i] + thickness[last]) / 2 + 2 * busSpacing { groups[groups.count - 1].append(i) }
                else { groups.append([i]) }
            }
            // Nearest group takes the lane closest to the hub.
            groups.sort { (cross[$0[0]] - reach) * side < (cross[$1[0]] - reach) * side }
            var next = reach + side * busSpacing
            for group in groups {
                let members = group.map { others[$0] }
                let low = ([hub] + members).map { along($0.bounds).lowerBound }.min()!, high = ([hub] + members).map { along($0.bounds).upperBound }.max()!
                let blockers = graph.nodes.filter { $0 !== hub && $0.width > 0 && $0.height > 0 && along($0.bounds).upperBound >= low && along($0.bounds).lowerBound <= high }.map { lane($0.bounds) }
                var position = next, moved = true
                while moved {
                    moved = false
                    for r in blockers where r.lowerBound - busSpacing / 2 <= position && position <= r.upperBound + busSpacing / 2 {
                        position = side > 0 ? r.upperBound + busSpacing / 2 + 1 : r.lowerBound - busSpacing / 2 - 1; moved = true
                    }
                }
                next = position + side * busSpacing / 2
                let joints = RoutingCompute.current?.bus(hub.center, others: members.map(\.center), coordinate: position, horizontal: horizontal)
                for (k, i) in group.enumerated() where processed.insert(edges[i]).inserted {
                    let e = edges[i], other = others[i]
                    let p = joints?[k * 2] ?? point(position, horizontal ? hub.center.x : hub.center.y)
                    let q = joints?[k * 2 + 1] ?? point(position, horizontal ? other.center.x : other.center.y)
                    var path = compactPath([hub.center, p, q, other.center])
                    let obstacles = ObstaclePolyline.obstacles(e, graph)
                    if !ObstaclePolyline.clear(path, obstacles) { path = detourBlocked(path, obstacles) }
                    e.path = e.source === hub ? path : Array(path.reversed())
                }
            }
        }
        for e in graph.edges where e.source !== e.target && !processed.contains(e) && e.path.count <= 2 { e.path = [e.source.center, e.target.center] }
    }
}
/// Rounds the corners of existing routes. Each corner becomes a quadratic arc of at most `radius`, never taking
/// more than half of either adjacent segment, so the first and last segments keep their direction. A corner whose
/// arc would touch a node stays sharp.
public final class CurveFittingEdgeRouter: EdgeRouter {
    /// Subdivision depth of a rounded corner: at most 2^iterations segments (up to 2^5); 0 leaves routes alone.
    public var iterations = 2
    public var radius = 10.0
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) { fitCurves(graph) }
    public func fitCurves(_ graph: LayoutGraph) {
        guard iterations > 0, radius > 0, radius.isFinite else { return }
        let steps = 1 << min(5, iterations)
        for e in graph.edges where e.source !== e.target && e.path.count > 2 {
            if RoutingCompute.isCancelled { return }
            let p = e.path, obstacles = ObstaclePolyline.obstacles(e, graph)
            let arcs = (1..<(p.count - 1)).map { Self.arc(p[$0 - 1], p[$0], p[$0 + 1], radius: radius, steps: steps) }
            let rounded = [p[0]] + (1..<(p.count - 1)).flatMap { arcs[$0 - 1] ?? [p[$0]] } + [p[p.count - 1]]
            let clear = ObstaclePolyline.clear(rounded, obstacles)
            var next = [p[0]]
            for i in 1..<(p.count - 1) {
                if let arc = arcs[i - 1], (clear || Self.clear(arc, obstacles)), Self.clear(arc, [e.source, e.target].map(\.bounds).filter { !$0.contains(arc[0]) && !$0.contains(arc[arc.count - 1]) }) {
                    next += arc
                } else { next.append(p[i]) }
            }
            e.path = compactPath(next + [p[p.count - 1]])
        }
    }
    private static func clear(_ path: [Point], _ rects: [Rect]) -> Bool {
        !zip(path, path.dropFirst()).contains { a, b in rects.contains { $0.intersectsLine(a, b) } }
    }
    /// The arc replacing corner `p` between `a` and `b`, or nil for straight and doubled-back corners.
    private static func arc(_ a: Point, _ p: Point, _ b: Point, radius: Double, steps: Int) -> [Point]? {
        let u = a - p, v = b - p, lu = u.length, lv = v.length
        guard lu > 1e-9, lv > 1e-9, abs(u.x * v.y - u.y * v.x) > 1e-6 * lu * lv else { return nil }
        let r = min(radius, lu / 2, lv / 2), from = p + u / lu * r, to = p + v / lv * r
        // Keep chords near 4.5 units or longer so tight arcs do not turn into micro-segments.
        let n = max(1, min(steps, Int(((to - from).length + 2 * r) / 2 / 4.5)))
        return (0...n).map { i in
            let t = Double(i) / Double(n), s = 1 - t
            return from * (s * s) + p * (2 * s * t) + to * (t * t)
        }
    }
}
