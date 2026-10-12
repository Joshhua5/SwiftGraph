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
        guard let first = path.first, rect.contains(first), let k = path.indices.dropFirst().first(where: { !rect.contains(path[$0]) }) else { return path }
        let inside = path[k - 1], outside = path[k], delta = outside - inside
        var exit = 1.0
        if delta.x > 0 { exit = min(exit, (rect.right - inside.x) / delta.x) }
        if delta.x < 0 { exit = min(exit, (rect.left - inside.x) / delta.x) }
        if delta.y > 0 { exit = min(exit, (rect.bottom - inside.y) / delta.y) }
        if delta.y < 0 { exit = min(exit, (rect.top - inside.y) / delta.y) }
        return compactPath([inside + delta * max(0, exit)] + Array(path[k...]))
    }
}

public final class SelfLoopRouter: EdgeRouter {
    public var loopWidth: Double = 60
    public var loopHeight: Double = 60
    /// Try alternate sides and smaller loops when a compact layout blocks the legacy top loop.
    public var avoidObstacles = false
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        unroutableEdges = []
        for edge in graph.edges where edge.source === edge.target {
            let r = edge.source.bounds, half = loopWidth / 2, y = r.y - loopHeight
            edge.path = [Point(x: r.center.x - half * 0.4, y: r.y), Point(x: r.center.x - half, y: y), Point(x: r.center.x + half, y: y), Point(x: r.center.x + half * 0.4, y: r.y)]
            guard avoidObstacles else { continue }
            let obstacles = ObstaclePolyline.obstacles(edge, graph)
            if ObstaclePolyline.clear(edge.path, obstacles) { continue }
            var result: [Point]?
            for scale in [1.0, 0.5, 0.25, 0.125] {
                for side in 0..<4 {
                    let horizontal = side % 2 == 0
                    let extent = horizontal ? r.width : r.height
                    let h = min(max(1, loopWidth * scale / 2), extent / 2)
                    let depth = max(1, loopHeight * scale)
                    let offsets = [-h * 0.4, -h, h, h * 0.4]
                    let path = offsets.enumerated().map { i, offset -> Point in
                        let outside = i == 1 || i == 2 ? depth : 0
                        switch side {
                        case 0: return Point(x: r.center.x + offset, y: r.top - outside)
                        case 1: return Point(x: r.right + outside, y: r.center.y + offset)
                        case 2: return Point(x: r.center.x - offset, y: r.bottom + outside)
                        default: return Point(x: r.left - outside, y: r.center.y - offset)
                        }
                    }
                    if ObstaclePolyline.clear(path, obstacles) { result = path; break }
                }
                if result != nil { break }
            }
            edge.path = result ?? []
            if result == nil { unroutableEdges.append(edge) }
        }
    }
}
public final class OctilinearEdgeRouter: EdgeRouter {
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        for e in graph.edges where e.source !== e.target {
            let a = e.source.center, b = e.target.center, d = b - a, diagonal = min(abs(d.x), abs(d.y))
            let bend = a + Point(x: d.x >= 0 ? diagonal : -diagonal, y: d.y >= 0 ? diagonal : -diagonal)
            e.path = [a] + ((bend - a).length > 1 && (bend - b).length > 1 ? [bend] : []) + [b]
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
            for (i, e) in edges.enumerated() {
                let offset = (Double(i) - Double(edges.count - 1) / 2) * edgeSpacing
                e.path = edges.count == 1 ? [e.source.center, e.target.center] : [e.source.center, (a + b) / 2 + normal * offset, e.target.center]
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
            for e in edges where processed.insert(e).inserted {
                let other = e.source === hub ? e.target : e.source
                let p = horizontal ? Point(x: hub.center.x, y: bus) : Point(x: bus, y: hub.center.y)
                let q = horizontal ? Point(x: other.center.x, y: bus) : Point(x: bus, y: other.center.y)
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
                var next = [p[0], p[0] * 0.25 + p[1] * 0.75]
                if p.count > 3 { for i in 1..<(p.count - 2) { next += [p[i] * 0.75 + p[i + 1] * 0.25, p[i] * 0.25 + p[i + 1] * 0.75] } }
                next += [p[p.count - 2] * 0.75 + p[p.count - 1] * 0.25, p.last!]; e.path = next
            }
        }
    }
}
