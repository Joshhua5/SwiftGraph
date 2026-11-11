import Foundation

/// Hubs with three or more edges get a bus: each edge leaves the hub, runs along a lane in a gap beside the nodes and
/// turns into its leaf. Leaves are grouped by column (or row) and every group has its own parallel lane, so the shared
/// stretch shows which leaves belong together. Legs that would cross a node are detoured
/// (rectilinearly where they can be).
public final class BusEdgeRouter: EdgeRouter {
    public var busSpacing: Float = 20

    public init() {}

    public func routeEdges(_ graph: LayoutGraph) {
        graph.routeStyle = .orthogonal
        var processed = Set<LayoutEdge>()
        var legs: [(edge: LayoutEdge, fromHub: Bool, path: [Point], obstacles: [Rect], blocked: Bool)] = []
        for (position, hub) in graph.nodes.enumerated() {
            if RoutingCompute.isCancelled { return }
            LayoutStageScope.tick(position, of: graph.nodes.count)
            let edges = graph.edges.filter { $0.source !== $0.target && ($0.source === hub || $0.target === hub) }
            guard edges.count >= 3 else { continue }
            let others = edges.map { $0.source === hub ? $0.target : $0.source }
            // The guard above leaves at least three edges, so `others` is non-empty.
            let horizontal =
                others.map(\.x).max()! - others.map(\.x).min()! > others.map(\.y).max()! - others.map(\.y).min()!
            let mean = others.reduce(Point.zero) { $0 + $1.center } / Float(others.count)
            // Lanes sit across the trunk axis: y for a horizontal bus, x for a vertical one.
            let side: Float = (horizontal ? mean.y >= hub.center.y : mean.x >= hub.center.x) ? 1 : -1
            func lane(_ r: Rect) -> ClosedRange<Float> { horizontal ? r.top...r.bottom : r.left...r.right }
            func along(_ r: Rect) -> ClosedRange<Float> { horizontal ? r.left...r.right : r.top...r.bottom }
            func point(_ lane: Float, _ along: Float) -> Point {
                horizontal ? Point(x: along, y: lane) : Point(x: lane, y: along)
            }
            let hubLane = lane(hub.bounds)
            let reach = side > 0 ? hubLane.upperBound : hubLane.lowerBound
            let cross = others.map { horizontal ? $0.center.y : $0.center.x }
            let thickness = others.map { lane($0.bounds).upperBound - lane($0.bounds).lowerBound }
            var groups: [[Int]] = []
            for i in others.indices.sorted(by: { cross[$0] == cross[$1] ? $0 < $1 : cross[$0] < cross[$1] }) {
                if let last = groups.last?.last,
                    cross[i] - cross[last] <= (thickness[i] + thickness[last]) / 2 + 2 * busSpacing
                {
                    groups[groups.count - 1].append(i)
                } else {
                    groups.append([i])
                }
            }
            // Nearest group takes the lane closest to the hub.
            groups.sort { (cross[$0[0]] - reach) * side < (cross[$1[0]] - reach) * side }
            var next = reach + side * busSpacing
            for group in groups {
                let members = group.map { others[$0] }
                // `[hub] + members` always contains the hub.
                let low = ([hub] + members).map { along($0.bounds).lowerBound }.min()!
                let high = ([hub] + members).map { along($0.bounds).upperBound }.max()!
                let blockers = graph.nodes
                    .filter {
                        $0 !== hub && $0.width > 0 && $0.height > 0 && along($0.bounds).upperBound >= low
                            && along($0.bounds).lowerBound <= high
                    }
                    .map { lane($0.bounds) }
                var position = next
                var moved = true
                while moved {
                    moved = false
                    for r in blockers
                    where r.lowerBound - busSpacing / 2 <= position && position <= r.upperBound + busSpacing / 2 {
                        position = side > 0 ? r.upperBound + busSpacing / 2 + 1 : r.lowerBound - busSpacing / 2 - 1
                        moved = true
                    }
                }
                next = position + side * busSpacing / 2
                let joints = RoutingCompute.current?
                    .bus(hub.center, others: members.map(\.center), coordinate: position, horizontal: horizontal)
                for (k, i) in group.enumerated() where processed.insert(edges[i]).inserted {
                    let e = edges[i]
                    let other = others[i]
                    let p = joints?[k * 2] ?? point(position, horizontal ? hub.center.x : hub.center.y)
                    let q = joints?[k * 2 + 1] ?? point(position, horizontal ? other.center.x : other.center.y)
                    let path = compactPath([hub.center, p, q, other.center])
                    let obstacles = ObstaclePolyline.obstacles(e, graph)
                    legs.append((e, e.source === hub, path, obstacles, !ObstaclePolyline.clear(path, obstacles)))
                }
            }
        }
        // A detour depends only on its own leg and the nodes, never on other routes, so blocked legs are searched
        // concurrently once every hub has claimed its edges.
        let blocked = legs.indices.filter { legs[$0].blocked }
        let detours = concurrentRoutingMap(blocked.map { (legs[$0].path, legs[$0].obstacles) }) {
            detourBlocked($0.0, $0.1, rectilinear: true)
        }
        if RoutingCompute.isCancelled { return }
        for (k, i) in blocked.enumerated() { legs[i].path = detours[k] }
        for leg in legs { leg.edge.path = leg.fromHub ? leg.path : Array(leg.path.reversed()) }
        for e in graph.edges where e.source !== e.target && !processed.contains(e) && e.path.count <= 2 {
            e.path = [e.source.center, e.target.center]
        }
    }
}
