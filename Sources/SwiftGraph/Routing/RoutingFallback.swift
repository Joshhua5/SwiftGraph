import Foundation

/// Last resorts for orthogonal routers when their own search fails: an orthogonal L/Z between side ports if one is
/// clear, otherwise an obstacle-aware polyline between those ports, then the least bad L/Z, and only then a straight
/// line.
enum RoutingFallback {
    static func route(_ edge: LayoutEdge, _ graph: LayoutGraph, padding: Float = 10) -> [Point] {
        let flow = OrthogonalPorts.flow(graph).vertical
        let from =
            OrthogonalPorts.ranked(
                edge.source,
                other: edge.target,
                active: edge.sourcePort,
                candidates: edge.sourcePortCandidates,
                vertical: flow
            )
            .prefix(2)
        let to =
            OrthogonalPorts.ranked(
                edge.target,
                other: edge.source,
                active: edge.targetPort,
                candidates: edge.targetPortCandidates,
                vertical: flow
            )
            .prefix(2)
        let obstacles = ObstaclePolyline.obstacles(edge, graph)
        let ends = [edge.source.bounds, edge.target.bounds].filter { $0.width > 0 && $0.height > 0 }
            .map(ObstaclePolyline.interior)
        var lz: [[Point]] = []
        var combos: [(Point, Point, Point, Point)] = []
        for a in from {
            for b in to {
                let ps = OrthogonalPorts.point(edge.source, side: a, toward: edge.target.bounds)
                let pt = OrthogonalPorts.point(edge.target, side: b, toward: edge.source.bounds)
                combos.append((ps, portDirection(a), pt, portDirection(b)))
                if let path = orthogonal(ps, portDirection(a), pt, portDirection(b)) { lz.append(path) }
            }
        }
        func clear(_ path: [Point]) -> Bool {
            ObstaclePolyline.clear(path, obstacles)
                && !zip(path, path.dropFirst()).contains { a, b in ends.contains { $0.intersectsLine(a, b) } }
        }
        if let path = lz.first(where: clear) { return path }
        for (ps, ds, pt, dt) in combos {
            // Search from just outside each port, so the route leaves and arrives perpendicular to its side.
            let a = ps + ds * padding
            let b = pt + dt * padding
            if let found = ObstaclePolyline.search(
                a,
                b,
                obstacles + [edge.source.bounds, edge.target.bounds],
                padding: padding
            ), found.count >= 2 {
                let path = compactPath([ps] + found + [pt])
                if clear(path) { return path }
            }
        }
        if let path = lz.min(by: { hits($0, obstacles) < hits($1, obstacles) }) { return path }
        return [edge.source.center, edge.target.center]
    }

    private static func hits(_ path: [Point], _ obstacles: [Rect]) -> Int {
        zip(path, path.dropFirst()).reduce(0) { n, s in n + obstacles.filter { $0.intersectsLine(s.0, s.1) }.count }
    }

    /// L between perpendicular ports, Z between facing ones, U between ports on the same side; nil if the ports face
    /// away.
    private static func orthogonal(_ ps: Point, _ ds: Point, _ pt: Point, _ dt: Point) -> [Point]? {
        let sv = ds.x == 0
        let tv = dt.x == 0
        if sv != tv {
            let corner = sv ? Point(x: ps.x, y: pt.y) : Point(x: pt.x, y: ps.y)
            return (corner - ps).x * ds.x + (corner - ps).y * ds.y > 1e-5
                && (corner - pt).x * dt.x + (corner - pt).y * dt.y > 1e-5 ? compactPath([ps, corner, pt]) : nil
        }
        let along = sv ? Point(x: 0, y: 1) : Point(x: 1, y: 0)
        func at(_ p: Point) -> Float { p.x * along.x + p.y * along.y }
        func place(_ q: Point, _ v: Float) -> Point { sv ? Point(x: q.x, y: v) : Point(x: v, y: q.y) }
        let sign = ds.x + ds.y
        if ds.x == -dt.x && ds.y == -dt.y {
            guard (at(pt) - at(ps)) * sign > 1e-5 else { return nil }
            let mid = (at(ps) + at(pt)) / 2
            return compactPath([ps, place(ps, mid), place(pt, mid), pt])
        }
        let far = sign > 0 ? max(at(ps), at(pt)) + 20 : min(at(ps), at(pt)) - 20
        return compactPath([ps, place(ps, far), place(pt, far), pt])
    }
}
