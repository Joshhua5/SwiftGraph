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
func choosePort(_ node: LayoutNode, toward: Point, constraint: PortConstraint, candidates: [PortConstraint]) -> PortConstraint {
    if constraint != .none { return constraint }
    let valid = candidates.filter { $0 != .none }
    if !valid.isEmpty {
        return valid.min { (portPoint(node, side: $0) - toward).lengthSquared < (portPoint(node, side: $1) - toward).lengthSquared }!
    }
    let d = toward - node.center
    return abs(d.x) > abs(d.y) ? (d.x >= 0 ? .right : .left) : (d.y >= 0 ? .bottom : .top)
}
func isAncestor(_ ancestor: LayoutNode, of node: LayoutNode) -> Bool {
    var current = node.parent, seen = Set<LayoutNode>()
    while let parent = current, seen.insert(parent).inserted {
        if parent === ancestor { return true }; current = parent.parent
    }
    return false
}
func routeObstacles(_ graph: LayoutGraph, edge: LayoutEdge, margin: Double, includeEndpoints: Bool = false) -> [Rect] {
    graph.nodes.compactMap { n in
        if n === edge.source || n === edge.target { return includeEndpoints ? n.bounds.inflated(by: -1e-7) : nil }
        if n.isGroup && (isAncestor(n, of: edge.source) || isAncestor(n, of: edge.target)) { return nil }
        return n.bounds.inflated(by: margin)
    }
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
struct MinHeap<Value> {
    private var items: [(Double, Int, Value)] = []
    private var sequence = 0
    mutating func push(_ value: Value, priority: Double) {
        items.append((priority, sequence, value)); sequence += 1
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if !less(i, p) { break }; items.swapAt(i, p); i = p
        }
    }
    private func less(_ a: Int, _ b: Int) -> Bool { items[a].0 == items[b].0 ? items[a].1 < items[b].1 : items[a].0 < items[b].0 }
    mutating func pop() -> Value? {
        guard !items.isEmpty else { return nil }
        if items.count == 1 { return items.removeLast().2 }
        let result = items[0].2; items[0] = items.removeLast()
        var i = 0
        while 2 * i + 1 < items.count {
            var j = 2 * i + 1
            if j + 1 < items.count && less(j + 1, j) { j += 1 }
            if !less(j, i) { break }; items.swapAt(i, j); i = j
        }
        return result
    }
}
private struct RouteState: Hashable { var x: Int; var y: Int; var direction: Int }
private struct RouteSegment: Hashable {
    let a: Point, b: Point
    init(_ a: Point, _ b: Point) {
        if a.x < b.x || (a.x == b.x && a.y < b.y) { self.a = a; self.b = b } else { self.a = b; self.b = a }
    }
}

/// Shared obstacle-aware rectilinear search used by channel, BSP and grouped routing.
final class OrthogonalSearch {
    var margin: Double = 10
    var bendPenalty: Double = 40
    var congestionPenalty: Double = 40
    var extraX: [Double] = [], extraY: [Double] = []
    private var usage: [RouteSegment: Int] = [:]
    func route(_ edge: LayoutEdge, in graph: LayoutGraph, offset: Double = 0) -> [Point]? {
        func sides(_ node: LayoutNode, toward: Point, constraint: PortConstraint, candidates: [PortConstraint]) -> [PortConstraint] {
            if constraint != .none { return [constraint] }
            let preferred = choosePort(node, toward: toward, constraint: constraint, candidates: candidates)
            let allowed = candidates.filter { $0 != .none }
            return [preferred] + (allowed.isEmpty ? [.top, .bottom, .left, .right] : allowed).filter { $0 != preferred }
        }
        let sources = sides(edge.source, toward: edge.target.center, constraint: edge.sourcePort, candidates: edge.sourcePortCandidates)
        let targets = sides(edge.target, toward: edge.source.center, constraint: edge.targetPort, candidates: edge.targetPortCandidates)
        let requestedMargin = margin
        defer { margin = requestedMargin }
        // Clearance is a preference. A narrow but valid corridor is better than an unroutable edge.
        for clearance in requestedMargin > 0 ? [requestedMargin, 0] : [0] {
            margin = clearance
            for source in sources { for target in targets {
                if let path = route(edge, in: graph, offset: offset, sourceSide: source, targetSide: target) { return path }
            } }
        }
        return nil
    }
    private func route(_ edge: LayoutEdge, in graph: LayoutGraph, offset: Double, sourceSide: PortConstraint, targetSide: PortConstraint) -> [Point]? {
        var start = portPoint(edge.source, side: sourceSide), end = portPoint(edge.target, side: targetSide)
        func shift(_ p: Point, node: LayoutNode, side: PortConstraint) -> Point {
            if side == .top || side == .bottom { return Point(x: min(node.bounds.right, max(node.x, p.x + offset)), y: p.y) }
            return Point(x: p.x, y: min(node.bounds.bottom, max(node.y, p.y + offset)))
        }
        start = shift(start, node: edge.source, side: sourceSide); end = shift(end, node: edge.target, side: targetSide)
        let clearance = max(1, margin + 1)
        let from = start + portDirection(sourceSide) * clearance, to = end + portDirection(targetSide) * clearance
        let obstacles = routeObstacles(graph, edge: edge, margin: max(0, margin), includeEndpoints: true)
        func clear(_ a: Point, _ b: Point) -> Bool { !obstacles.contains { $0.intersectsLine(a, b) } }
        guard clear(start, from), clear(to, end) else { return nil }
        var xs = [from.x, to.x] + extraX, ys = [from.y, to.y] + extraY
        for r in obstacles { xs += [r.left - 1, r.right + 1]; ys += [r.top - 1, r.bottom + 1] }
        xs = Array(Set(xs)).sorted(); ys = Array(Set(ys)).sorted()
        let initial = RouteState(x: xs.firstIndex(of: from.x)!, y: ys.firstIndex(of: from.y)!, direction: sourceSide == .top || sourceSide == .bottom ? 1 : 0)
        let targetX = xs.firstIndex(of: to.x)!, targetY = ys.firstIndex(of: to.y)!
        var queue = MinHeap<RouteState>(), costs: [RouteState: Double] = [initial: 0], previous: [RouteState: RouteState] = [:], closed = Set<RouteState>()
        queue.push(initial, priority: 0)
        var finish: RouteState?
        while let current = queue.pop() {
            if Task.isCancelled { return nil }
            if !closed.insert(current).inserted { continue }
            if current.x == targetX && current.y == targetY { finish = current; break }
            let p = Point(x: xs[current.x], y: ys[current.y])
            for (dx, dy, direction) in [(1, 0, 0), (0, 1, 1), (-1, 0, 0), (0, -1, 1)] {
                let x = current.x + dx, y = current.y + dy
                guard x >= 0, y >= 0, x < xs.count, y < ys.count else { continue }
                let q = Point(x: xs[x], y: ys[y])
                guard clear(p, q) else { continue }
                let next = RouteState(x: x, y: y, direction: direction)
                let cost = costs[current]! + (q - p).length + (direction == current.direction ? 0 : max(0, bendPenalty)) + Double(usage[RouteSegment(p, q), default: 0]) * max(0, congestionPenalty)
                if cost < costs[next, default: .infinity] {
                    costs[next] = cost; previous[next] = current
                    queue.push(next, priority: cost + abs(q.x - to.x) + abs(q.y - to.y))
                }
            }
        }
        guard var current = finish else { return nil }
        var middle = [Point(x: xs[current.x], y: ys[current.y])]
        while let p = previous[current] { current = p; middle.append(Point(x: xs[p.x], y: ys[p.y])) }
        middle.reverse()
        for (p, q) in zip(middle, middle.dropFirst()) { usage[RouteSegment(p, q), default: 0] += 1 }
        return compactPath([start] + middle + [end])
    }
}

public final class ChannelEdgeRouter: EdgeRouter {
    public var gridSize = 20
    public var bendPenalty = 2
    public var congestionPenalty = 2
    /// No invalid fallback is silently emitted when obstacles make a route impossible.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        let search = OrthogonalSearch()
        search.margin = max(1, Double(gridSize) / 2)
        search.bendPenalty = Double(max(0, bendPenalty) * max(1, gridSize))
        search.congestionPenalty = Double(max(0, congestionPenalty) * max(1, gridSize))
        unroutableEdges = []
        for edge in graph.edges where edge.source !== edge.target {
            if let path = search.route(edge, in: graph) { edge.path = path }
            else { edge.path = []; unroutableEdges.append(edge) }
        }
    }
}

public final class PolylineEdgeRouter: EdgeRouter {
    public var padding: Double = 10
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        let search = OrthogonalSearch(); search.margin = max(0, padding)
        unroutableEdges = []
        for edge in graph.edges where edge.source !== edge.target {
            let obstacles = routeObstacles(graph, edge: edge, margin: max(0, padding))
            let start = edge.source.center, end = edge.target.center
            if edge.sourcePort == .none && edge.targetPort == .none && edge.sourcePortCandidates.isEmpty && edge.targetPortCandidates.isEmpty && !obstacles.contains(where: { $0.intersectsLine(start, end) }) {
                edge.path = [start, end]
            } else if let path = search.route(edge, in: graph) {
                // Visibility shortcutting turns the rectilinear detour into a polyline.
                var result = [path[0]], i = 0
                let allObstacles = routeObstacles(graph, edge: edge, margin: max(0, padding), includeEndpoints: true)
                while i < path.count - 1 {
                    var j = path.count - 1
                    if i == 0 && (edge.sourcePort != .none || !edge.sourcePortCandidates.isEmpty) { j = i + 1 }
                    while j > i + 1 && (allObstacles.contains { $0.intersectsLine(path[i], path[j]) } || (j == path.count - 1 && (edge.targetPort != .none || !edge.targetPortCandidates.isEmpty))) { j -= 1 }
                    result.append(path[j]); i = j
                }
                edge.path = result
            } else { edge.path = []; unroutableEdges.append(edge) }
        }
    }
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
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        for edge in graph.edges where edge.source === edge.target {
            let r = edge.source.bounds, half = loopWidth / 2, y = r.y - loopHeight
            edge.path = [Point(x: r.center.x - half * 0.4, y: r.y), Point(x: r.center.x - half, y: y), Point(x: r.center.x + half, y: y), Point(x: r.center.x + half * 0.4, y: r.y)]
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
