import Foundation

public enum EdgeEndpointClipper {
    /// Trims each route to the last exit from its source and the first entry into its target. Routes that
    /// would be left with fewer than two points stay as they were.
    public static func clipToNodeBounds(_ graph: LayoutGraph) {
        for edge in graph.edges where edge.source !== edge.target && edge.path.count >= 2 {
            edge.path = clipped(edge.path, source: edge.source.bounds, target: edge.target.bounds)
        }
    }

    static func clipped(_ path: [Point], source: Rect, target: Rect) -> [Point] {
        let start = clipStart(path, to: source)
        return Array(clipStart(Array(start.reversed()), to: target).reversed())
    }

    private static func clipStart(_ path: [Point], to rect: Rect) -> [Point] {
        let inside = RoutingCompute.current?.contains(path, rect) ?? path.map(rect.contains)
        guard inside.first == true, inside.last == false else { return path }
        let core = ObstaclePolyline.interior(rect)
        for k in stride(from: path.count - 2, through: 0, by: -1) {
            let a = path[k]
            let b = path[k + 1]
            // A segment may cross the node without a vertex inside it; grazing the boundary does not count.
            guard inside[k] || (core.width > 0 && core.height > 0 && core.intersectsLine(a, b)),
                let t = exit(a, b, rect)
            else { continue }
            let point = a + (b - a) * t
            var rest = Array(path[(k + 1)...])
            // A sample hugging the boundary would leave a micro-segment; absorb it unless it is a real bend.
            if rest.count > 1, (rest[0] - point).length < 4, Self.shallow(point, rest[0], rest[1]) {
                rest.removeFirst()
            }
            let clipped = compactPath([point] + rest)
            return clipped.count >= 2 ? clipped : path
        }
        return path
    }

    private static func shallow(_ a: Point, _ b: Point, _ c: Point) -> Bool {
        let u = b - a
        let v = c - b
        let lu = u.length
        let lv = v.length
        return lu > 1e-6 && lv > 1e-6 && (u.x * v.x + u.y * v.y) / (lu * lv) > 0.9
    }

    /// Parameter at which segment `a`→`b` leaves `rect`, or nil when it misses it.
    private static func exit(_ a: Point, _ b: Point, _ rect: Rect) -> Float? {
        var lo: Float = 0.0
        var hi: Float = 1.0
        for (origin, delta, low, high) in [
            (a.x, b.x - a.x, rect.left, rect.right), (a.y, b.y - a.y, rect.top, rect.bottom),
        ] {
            if abs(delta) < 1e-6 {
                if origin < low || origin > high { return nil }
            } else {
                let t1 = (low - origin) / delta
                let t2 = (high - origin) / delta
                lo = max(lo, min(t1, t2))
                hi = min(hi, max(t1, t2))
                if lo > hi { return nil }
            }
        }
        return max(0, hi)
    }
}
