import Foundation

/// Rounds the corners of existing routes. Each corner becomes a quadratic arc of at most `radius`, never taking
/// more than half of either adjacent segment, so the first and last segments keep their direction. A corner whose
/// arc would touch a node stays sharp.
public final class CurveFittingEdgeRouter: EdgeRouter {
    /// Subdivision depth of a rounded corner: at most 2^iterations segments (up to 2^5); 0 leaves routes alone.
    public var iterations = 2
    public var radius: Float = 10.0

    public init() {}

    public func routeEdges(_ graph: LayoutGraph) { fitCurves(graph) }

    public func fitCurves(_ graph: LayoutGraph) {
        guard iterations > 0, radius > 0, radius.isFinite else { return }
        graph.routeStyle = .curved
        let steps = 1 << min(5, iterations)
        for (position, e) in graph.edges.enumerated() where e.source !== e.target && e.path.count > 2 {
            if RoutingCompute.isCancelled { return }
            if position & 15 == 0 { LayoutStageScope.tick(position, of: graph.edges.count) }
            let p = e.path
            let obstacles = ObstaclePolyline.obstacles(e, graph)
            let arcs = (1..<(p.count - 1)).map { Self.arc(p[$0 - 1], p[$0], p[$0 + 1], radius: radius, steps: steps) }
            let rounded = [p[0]] + (1..<(p.count - 1)).flatMap { arcs[$0 - 1] ?? [p[$0]] } + [p[p.count - 1]]
            let clear = ObstaclePolyline.clear(rounded, obstacles)
            var next = [p[0]]
            for i in 1..<(p.count - 1) {
                if let arc = arcs[i - 1], clear || Self.clear(arc, obstacles),
                    Self.clear(
                        arc,
                        [e.source, e.target].map(\.bounds)
                            .filter { !$0.contains(arc[0]) && !$0.contains(arc[arc.count - 1]) }
                    )
                {
                    next += arc
                } else {
                    next.append(p[i])
                }
            }
            e.path = compactPath(next + [p[p.count - 1]])
        }
    }

    private static func clear(_ path: [Point], _ rects: [Rect]) -> Bool {
        !zip(path, path.dropFirst()).contains { a, b in rects.contains { $0.intersectsLine(a, b) } }
    }

    /// The arc replacing corner `p` between `a` and `b`, or nil for straight and doubled-back corners.
    private static func arc(_ a: Point, _ p: Point, _ b: Point, radius: Float, steps: Int) -> [Point]? {
        let u = a - p
        let v = b - p
        let lu = u.length
        let lv = v.length
        guard lu > 1e-6, lv > 1e-6, abs(u.x * v.y - u.y * v.x) > 1e-5 * lu * lv else { return nil }
        let r = min(radius, lu / 2, lv / 2)
        let from = p + u / lu * r
        let to = p + v / lv * r
        // Keep chords near 4.5 units or longer so tight arcs do not turn into micro-segments.
        let n = max(1, min(steps, Int(((to - from).length + 2 * r) / 2 / 4.5)))
        return (0...n)
            .map { i in
                let t = Float(i) / Float(n)
                let s = 1 - t
                return from * (s * s) + p * (2 * s * t) + to * (t * t)
            }
    }
}
