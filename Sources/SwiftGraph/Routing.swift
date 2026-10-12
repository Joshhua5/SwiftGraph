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
    public static func clipToNodeBounds(_ graph: LayoutGraph) {
        for edge in graph.edges where edge.source !== edge.target && edge.path.count >= 2 {
            edge.path = clipStart(edge.path, to: edge.source.bounds)
            edge.path = Array(clipStart(Array(edge.path.reversed()), to: edge.target.bounds).reversed())
        }
    }
    private static func clipStart(_ path: [Point], to rect: Rect) -> [Point] {
        let containment = RoutingCompute.current?.contains(path, rect)
        guard let first = path.first, (containment?.first ?? rect.contains(first)), let k = path.indices.dropFirst().first(where: { !(containment?[$0] ?? rect.contains(path[$0])) }) else { return path }
        let inside = path[k - 1], outside = path[k], delta = outside - inside
        var exit = 1.0
        if delta.x > 0 { exit = min(exit, (rect.right - inside.x) / delta.x) }
        if delta.x < 0 { exit = min(exit, (rect.left - inside.x) / delta.x) }
        if delta.y > 0 { exit = min(exit, (rect.bottom - inside.y) / delta.y) }
        if delta.y < 0 { exit = min(exit, (rect.top - inside.y) / delta.y) }
        return compactPath([inside + delta * max(0, exit)] + Array(path[k...]))
    }
}

/// Routes self-loops as compact orthogonal corner loops: out of one side near a corner, `loopSize` round the
/// corner and back into the adjacent side. Each loop takes the corner that is clear of other nodes, crosses the
/// fewest routes and is furthest from where incident edges attach; further loops on a node take other corners,
/// then nest outward.
public final class SelfLoopRouter: EdgeRouter {
    /// How far a corner loop reaches beyond the node.
    public var loopSize: Double = 16
    /// Loops with no clear corner; they are still drawn at the best one.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        unroutableEdges = []
        let loops = graph.edges.filter { $0.source === $0.target }
        var pending = Set(loops), used: [LayoutNode: [Int]] = [:]
        for edge in loops {
            let node = edge.source, r = node.bounds, corners = used[node, default: []]
            let ring = Double(corners.count / 4), taken = Set(corners.suffix(corners.count % 4))
            let inset = min(max(min(r.width, r.height) / 4, 4), 16) + ring * 6
            let size = loopSize + ring * 6
            let obstacles = ObstaclePolyline.obstacles(edge, graph)
            // Loops still to be routed carry stale paths; leave them out of the crossing count.
            let routes = graph.edges.filter { $0 !== edge && !pending.contains($0) && $0.path.count >= 2 }.map(\.path)
            let attached = Self.attachments(node, graph)
            var best: (path: [Point], corner: Int, score: [Double])?, fallback: (path: [Point], corner: Int, score: [Double])?
            for scale in [1.0, 0.5] where best == nil {
                for corner in 0..<4 where !taken.contains(corner) {
                    let path = Self.loop(r, corner: corner, size: size * scale, inset: inset)
                    let score = [Double(Self.crossings(path, routes)), Double(attached[corner]), Double(corner)]
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
public final class OctilinearEdgeRouter: EdgeRouter {
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        let edges = graph.edges.filter { $0.source !== $0.target }
        let bends = RoutingCompute.current?.octilinear(edges.map { $0.source.center }, edges.map { $0.target.center })
        for (i, e) in edges.enumerated() {
            let a = e.source.center, b = e.target.center, d = b - a, diagonal = min(abs(d.x), abs(d.y))
            let bend = a + Point(x: d.x >= 0 ? diagonal : -diagonal, y: d.y >= 0 ? diagonal : -diagonal)
            e.path = [a] + ((bend - a).length > 1 && (bend - b).length > 1 ? [bends?[i] ?? bend] : []) + [b]
        }
    }
}
public final class ParallelEdgeRouter: EdgeRouter {
    public var edgeSpacing: Double = 20
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        var groups: [Set<LayoutNode>: [LayoutEdge]] = [:]
        for e in graph.edges where e.source !== e.target { groups[[e.source, e.target], default: []].append(e) }
        for edges in groups.values {
            let a = edges[0].source.center, b = edges[0].target.center, delta = b - a, length = max(0.001, delta.length)
            let normal = Point(x: -delta.y / length, y: delta.x / length)
            let offsets = edges.indices.map { (Double($0) - Double(edges.count - 1) / 2) * edgeSpacing }
            let midpoints = RoutingCompute.current?.parallel(Array(repeating: a, count: edges.count), Array(repeating: b, count: edges.count), offsets: offsets)
            for (i, e) in edges.enumerated() {
                let offset = (Double(i) - Double(edges.count - 1) / 2) * edgeSpacing
                e.path = edges.count == 1 ? [e.source.center, e.target.center] : [e.source.center, midpoints?[i] ?? ((a + b) / 2 + normal * offset), e.target.center]
            }
        }
    }
}
public final class BusEdgeRouter: EdgeRouter {
    public var busSpacing: Double = 20
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        var processed = Set<LayoutEdge>()
        for hub in graph.nodes {
            let edges = graph.edges.filter { $0.source !== $0.target && ($0.source === hub || $0.target === hub) }
            guard edges.count >= 3 else { continue }
            let others = edges.map { $0.source === hub ? $0.target : $0.source }
            let horizontal = others.map(\.x).max()! - others.map(\.x).min()! > others.map(\.y).max()! - others.map(\.y).min()!
            let mean = others.reduce(Point.zero) { $0 + $1.center } / Double(others.count)
            let bus = horizontal ? (mean.y >= hub.center.y ? hub.bounds.bottom + busSpacing : hub.y - busSpacing) : (mean.x >= hub.center.x ? hub.bounds.right + busSpacing : hub.x - busSpacing)
            let joints = RoutingCompute.current?.bus(hub.center, others: others.map(\.center), coordinate: bus, horizontal: horizontal)
            for (i, e) in edges.enumerated() where processed.insert(e).inserted {
                let other = e.source === hub ? e.target : e.source
                let p = joints?[i * 2] ?? (horizontal ? Point(x: hub.center.x, y: bus) : Point(x: bus, y: hub.center.y))
                let q = joints?[i * 2 + 1] ?? (horizontal ? Point(x: other.center.x, y: bus) : Point(x: bus, y: other.center.y))
                let path = [hub.center, p, q, other.center]
                e.path = e.source === hub ? path : Array(path.reversed())
            }
        }
        for e in graph.edges where e.source !== e.target && !processed.contains(e) && e.path.count <= 2 { e.path = [e.source.center, e.target.center] }
    }
}
public final class CurveFittingEdgeRouter: EdgeRouter {
    public var iterations = 2
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) { fitCurves(graph) }
    public func fitCurves(_ graph: LayoutGraph) {
        for e in graph.edges where e.source !== e.target && e.path.count > 2 {
            for _ in 0..<min(5, max(0, iterations)) {
                let p = e.path
                var aa = [p[0], p[0]], bb = [p[0], p[1]], weights = [0.0, 0.75]
                if p.count > 3 { for i in 1..<(p.count - 2) { aa += [p[i], p[i]]; bb += [p[i + 1], p[i + 1]]; weights += [0.25, 0.75] } }
                aa += [p[p.count - 2], p.last!]; bb += [p.last!, p.last!]; weights += [0.25, 0]
                var next = RoutingCompute.current?.blend(aa, bb, weights: weights) ?? aa.indices.map { aa[$0] * (1 - weights[$0]) + bb[$0] * weights[$0] }
                next[0] = p[0]; next[next.count - 1] = p.last!; e.path = next
            }
        }
    }
}
