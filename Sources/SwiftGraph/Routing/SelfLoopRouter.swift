import Foundation

/// Routes self-loops as compact orthogonal corner loops: out of one side near a corner, `loopSize` round the
/// corner and back into the adjacent side. Each loop takes the corner that is clear of other nodes, crosses the
/// fewest routes and is furthest from where incident edges attach; further loops on a node take other corners,
/// then nest outward.
public final class SelfLoopRouter: EdgeRouter {
    /// How far a corner loop reaches beyond the node.
    public var loopSize: Float = 16

    /// Clearance a loop keeps from other nodes.
    public var padding: Float = 4

    /// Unroutable edges are loops with no clear corner; they are still drawn at the best one.
    public private(set) var report = RoutingReport()

    /// Loops with no clear corner; they are still drawn at the best one.
    @available(*, deprecated, message: "Use report.unroutable or report.unroutableEdges(in:)")
    public var unroutableEdges: [LayoutEdge] { failed }

    private var failed: [LayoutEdge] = []

    public init() {}

    public func routeEdges(_ graph: LayoutGraph) {
        failed = []
        defer { report = RoutingReport(graph, unroutable: failed) }
        let loops = graph.edges.filter { $0.source === $0.target }
        var pending = Set(loops)
        var used: [LayoutNode: [Int]] = [:]
        let loopCounts = Dictionary(grouping: loops, by: \.source).mapValues(\.count)
        for (position, edge) in loops.enumerated() {
            if position & 15 == 0 { LayoutStageScope.tick(position, of: loops.count) }
            let node = edge.source
            let r = node.bounds
            let corners = used[node, default: []]
            let ring = Float(corners.count / 4)
            let taken = Set(corners.suffix(corners.count % 4))
            // Rings step outward by 6 along the sides; on small nodes the steps shrink to fit before the middle, so
            // legs stay apart.
            let cap = max(2, min(r.width, r.height) / 2 - 1.5)
            let base = min(max(min(r.width, r.height) / 4, 4), 16, cap)
            let rings = Float((loopCounts[node, default: 1] + 3) / 4)
            let inset = base + ring * (rings > 1 ? min(6, max(1, (cap - base) / (rings - 1))) : 6)
            let size = loopSize + ring * 6
            let obstacles = ObstaclePolyline.obstacles(edge, graph).map { $0.inflated(by: padding) }
            // Loops still to be routed carry stale paths; leave them out of the crossing count.
            let routes = graph.edges.filter { $0 !== edge && !pending.contains($0) && $0.path.count >= 2 }.map(\.path)
            let attached = Self.attachments(node, graph)
            var best: (path: [Point], corner: Int, score: [Float])?
            var fallback: (path: [Point], corner: Int, score: [Float])?
            for scale: Float in [1.0, 0.5] where best == nil {
                for corner in 0..<4 where !taken.contains(corner) {
                    let path = Self.loop(r, corner: corner, size: size * scale, inset: inset)
                    let score = [
                        Float(Self.overlaps(path, routes)), Float(Self.crossings(path, routes)),
                        Float(attached[corner]), Float(corner),
                    ]
                    // Each unwrap below runs only after its `== nil` check has short-circuited.
                    if ObstaclePolyline.clear(path, obstacles) {
                        if best == nil || score.lexicographicallyPrecedes(best!.score) { best = (path, corner, score) }
                    } else if scale == 1, fallback == nil || score.lexicographicallyPrecedes(fallback!.score) {
                        fallback = (path, corner, score)
                    }
                }
            }
            if best == nil { failed.append(edge) }
            if let chosen = best ?? fallback {
                edge.path = chosen.path
                used[node, default: []].append(chosen.corner)
            }
            pending.remove(edge)
        }
    }

    /// Corner 0 is top-right, then clockwise.
    private static func loop(_ r: Rect, corner: Int, size: Float, inset: Float) -> [Point] {
        let sx: Float = corner < 2 ? 1 : -1
        let sy: Float = corner == 0 || corner == 3 ? -1 : 1
        let cx = sx > 0 ? r.right : r.left
        let cy = sy < 0 ? r.top : r.bottom
        let a = min(inset, r.width / 2, r.height / 2)
        return [
            Point(x: cx - sx * a, y: cy), Point(x: cx - sx * a, y: cy + sy * size),
            Point(x: cx + sx * size, y: cy + sy * size),
            Point(x: cx + sx * size, y: cy - sy * a), Point(x: cx, y: cy - sy * a),
        ]
    }

    /// How many incident edges leave the node towards each corner's quadrant.
    private static func attachments(_ node: LayoutNode, _ graph: LayoutGraph) -> [Int] {
        var counts = [0, 0, 0, 0]
        let c = node.center
        for e in graph.edges
        where e.source !== e.target && (e.source === node || e.target === node) && e.path.count >= 2 {
            let path = e.source === node ? e.path : e.path.reversed()
            // A route starting at the centre shows its direction at the next point.
            let p = (path[0] - c).length > 1e-6 ? path[0] : path[1]
            counts[p.x >= c.x ? (p.y < c.y ? 0 : 1) : (p.y < c.y ? 3 : 2)] += 1
        }
        return counts
    }

    /// Segment pairs that run along the same line over a stretch; stacked edges read as one.
    private static func overlaps(_ path: [Point], _ routes: [[Point]]) -> Int {
        func cross(_ a: Point, _ b: Point) -> Float { a.x * b.y - a.y * b.x }
        var count = 0
        for (a, b) in zip(path, path.dropFirst()) {
            let u = b - a
            let length = u.length
            guard length > 1e-6 else { continue }
            for route in routes {
                for (c, d) in zip(route, route.dropFirst())
                where abs(cross(u, c - a)) < 1e-5 * length && abs(cross(u, d - a)) < 1e-5 * length {
                    let s = (c - a).x * u.x + (c - a).y * u.y
                    let e = (d - a).x * u.x + (d - a).y * u.y
                    if min(length * length, max(s, e)) - max(0, min(s, e)) > 1e-5 * length { count += 1 }
                }
            }
        }
        return count
    }

    private static func crossings(_ path: [Point], _ routes: [[Point]]) -> Int {
        func cross(_ a: Point, _ b: Point) -> Float { a.x * b.y - a.y * b.x }
        var count = 0
        let segments = Array(zip(path, path.dropFirst()))
        let other = routes.flatMap { Array(zip($0, $0.dropFirst())) }
        let flags = RoutingCompute.current?
            .candidates(
                segments.map { RoutingCompute.bounds($0.0, $0.1) },
                other.map { RoutingCompute.bounds($0.0, $0.1) }
            )
        for (i, segment) in segments.enumerated() {
            let (a, b) = segment
            // `flags!` runs only after `flags == nil` has short-circuited.
            for (j, pair) in other.enumerated() where flags == nil || flags![i * other.count + j] != 0 {
                let (c, d) = pair
                let u = b - a
                let v = d - c
                let denominator = cross(u, v)
                guard abs(denominator) > 1e-6 else { continue }
                let t = cross(c - a, v) / denominator
                let s = cross(c - a, u) / denominator
                if t > 1e-5 && t < 1 - 1e-5 && s > 1e-5 && s < 1 - 1e-5 { count += 1 }
            }
        }
        return count
    }
}
