import Foundation

/// Shortest polyline that keeps `padding` clear of every obstacle, finished with `EdgeSeparator`.
/// Detours prefer few bends, avoid crossing routes already laid, and fan out where several share a corner.
/// Ports are not interpreted.
public final class PolylineEdgeRouter: EdgeRouter {
    public var padding: Double = ObstaclePolyline.defaultPadding
    /// Spreads edges sharing a collinear stretch this far apart; 0 leaves them overlapping.
    public var edgeSpacing: Double = 10
    /// Cost of a half-turn in a detour, in length units; 0 chooses the shortest path alone.
    public var bendPenalty: Double = 20
    /// Cost of crossing a routed segment in a detour, in length units; 0 ignores crossings.
    public var crossingPenalty: Double = 40
    /// Edges with no clear route; they keep a straight centre-to-centre line so they stay visible.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    /// Edges that still share a stretch with another after separation (no room for lanes, or lanes would cut a node).
    public private(set) var unseparatedEdges: [LayoutEdge] = []
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        unroutableEdges = []; unseparatedEdges = []
        guard !graph.nodes.isEmpty else { return }
        let scene = ObstaclePolyline.Scene(graph.nodes), routed = ObstaclePolyline.SegmentIndex(bounds: scene.bounds)
        let edges = graph.edges.filter { $0.source !== $0.target }
        var corners: [Point: [ObstaclePolyline.Bend]] = [:], used = Array(repeating: [ObstaclePolyline.Bend](), count: edges.count), detoured: [Int] = []
        func route(_ i: Int) -> (path: [Point], gap: Double, bends: [ObstaclePolyline.Bend])? {
            scene.route(edges[i], padding: padding, bend: bendPenalty, crossing: crossingPenalty, routed: routed, corners: corners, fan: edgeSpacing)
        }
        func register(_ i: Int, _ bends: [ObstaclePolyline.Bend]) {
            for b in used[i] { corners[b.corner]?.removeAll { $0 == b } }
            for b in bends { corners[b.corner, default: []].append(b) }
            used[i] = bends
        }
        for (i, edge) in edges.enumerated() {
            if RoutingCompute.isCancelled { return }
            let found = route(i)
            if RoutingCompute.isCancelled { return }
            if let found { edge.path = found.path; register(i, found.bends) } else { unroutableEdges.append(edge); edge.path = [edge.source.center, edge.target.center] }
            if edge.path.count > 2 { detoured.append(i) }
            routed.add(edge.path, owner: i)
        }
        // One rip-up pass: a detour found early could not see the routes laid after it.
        if crossingPenalty > 0 {
            for i in detoured {
                if RoutingCompute.isCancelled { return }
                let edge = edges[i], old = edge.path
                routed.remove(owner: i)
                let before = ObstaclePolyline.cost(old, bend: bendPenalty, crossing: crossingPenalty, routed: routed)
                if let found = route(i), ObstaclePolyline.cost(found.path, bend: bendPenalty, crossing: crossingPenalty, routed: routed) < before - 1e-9 {
                    edge.path = found.path; register(i, found.bends)
                }
                routed.add(edge.path, owner: i)
            }
        }
        if edgeSpacing > 0 {
            let separator = EdgeSeparator(); separator.spacing = edgeSpacing; separator.separate(edges, scene)
            unseparatedEdges = separator.unseparatedEdges
        }
    }
}

/// Obstacle-aware visibility search, shared by the polyline router and layout repairs.
enum ObstaclePolyline {
    static let defaultPadding = 10.0

    /// The obstacles of one routing pass, indexed once; a window around each edge is searched first and
    /// widened only when the route found would cut something outside it.
    struct Scene {
        let nodes: [LayoutNode], rects: [Rect], bounds: Rect
        private let tree: QuadTree<Int>
        init(_ all: [LayoutNode]) {
            let sized = all.filter { $0.bounds.width > 0 && $0.bounds.height > 0 }
            nodes = sized; rects = sized.map(\.bounds)
            bounds = rects.isEmpty ? Rect() : rects.dropFirst().reduce(rects[0]) { $0.union($1) }.inflated(by: 1)
            tree = QuadTree<Int>(bounds: bounds)
            for (i, r) in rects.enumerated() { tree.insert(bounds: r, item: i) }
        }
        /// Every obstacle touching `area`, in index order.
        func within(_ area: Rect) -> [Int] { tree.query(area.inflated(by: 1e-6)).sorted() }
        /// Obstacles of `edge` touching `area`: everything but its own ends and the groups containing them.
        func near(_ area: Rect, _ edge: LayoutEdge) -> [Int] {
            within(area).filter { i in
                let n = nodes[i]
                return n !== edge.source && n !== edge.target &&
                    !(n.isGroup && (isAncestor(n, of: edge.source) || isAncestor(n, of: edge.target)))
            }
        }
        func clear(_ path: [Point], _ edge: LayoutEdge) -> Bool {
            ObstaclePolyline.clear(path, near(ObstaclePolyline.bounds(path), edge).map { rects[$0] })
        }
        /// As `near`, less a node an endpoint merely sits in (a group centre inside a child), which cannot be avoided.
        fileprivate func relevant(_ area: Rect, _ edge: LayoutEdge, _ start: Point, _ end: Point) -> [Int] {
            func covers(_ r: Rect, _ b: Rect) -> Bool { r.left <= b.left && r.right >= b.right && r.top <= b.top && r.bottom >= b.bottom }
            let source = edge.source.bounds, target = edge.target.bounds
            return near(area, edge).filter { i in
                let r = rects[i]
                return !(r.contains(start) && !covers(r, source)) && !(r.contains(end) && !covers(r, target))
            }
        }
        /// Obstacles outside `included` that the route would cut, judged as the search judges them.
        private func violators(_ path: [Point], _ included: Set<Int>, _ edge: LayoutEdge, gap: Double) -> [Int] {
            let start = path[0], end = path[path.count - 1]
            return relevant(ObstaclePolyline.bounds(path).inflated(by: gap), edge, start, end).filter { i in
                guard !included.contains(i) else { return false }
                let probe = ObstaclePolyline.probe(rects[i], start, end, gap, straight: path.count == 2)
                return zip(path, path.dropFirst()).contains { probe.intersectsLine($0, $1) }
            }
        }
        /// The route of `edge` with the padding it was found at and the corners it bends at; nil when no clear route
        /// exists. Padding is halved, quartered and finally cut to about 1 when padded obstacles seal a corridor.
        /// `corners` holds the bends already at each padded corner, and `fan` is how far apart later ones are spread.
        func route(_ edge: LayoutEdge, padding: Double, bend: Double = 0, crossing: Double = 0, routed: SegmentIndex? = nil,
                   corners: [Point: [Bend]] = [:], fan: Double = 0) -> (path: [Point], gap: Double, bends: [Bend])? {
            let start = edge.source.center, end = edge.target.center
            let gap = padding.isFinite ? max(1e-5, padding) : 10
            var ladder = [gap]
            for g in [gap / 2, gap / 4, 1.0] where g < ladder[ladder.count - 1] { ladder.append(g) }
            let window = ObstaclePolyline.bounds([start, end]).inflated(by: 2 * gap + (end - start).length / 4)
            let initial = Set(relevant(window, edge, start, end))
            var extra: ((Point, Point) -> Double)?
            if let routed, crossing > 0 { extra = { a, b in crossing * Double(routed.crossings(a, b)) } }
            for level in ladder {
                var included = initial
                while true {
                    guard let path = ObstaclePolyline.search(start, end, included.sorted().map { rects[$0] }, padding: level, bend: bend, extra: extra) else { break }
                    let more = violators(path, included, edge, gap: level)
                    if more.isEmpty {
                        let bends = path.indices.dropFirst().dropLast().map { Bend(corner: path[$0], toward: path[$0 - 1] - path[$0], away: path[$0 + 1] - path[$0]) }
                        guard fan > 0, path.count > 2 else { return (path, level, bends) }
                        return (spread(path, corners, edge, routed, gap: level, step: fan), level, bends)
                    }
                    included.formUnion(more)
                }
                if RoutingCompute.isCancelled { return nil }
            }
            if clear([start, end], edge) { return ([start, end], gap, []) }
            return nil
        }
        /// Edges bending at one padded corner would read as a junction: each later one bends a step further out,
        /// unless that would clear a node's padding or add a crossing. Bends that run alike are left to the separator.
        private func spread(_ path: [Point], _ corners: [Point: [Bend]], _ edge: LayoutEdge, _ routed: SegmentIndex?, gap: Double, step: Double) -> [Point] {
            var path = path
            let start = path[0], end = path[path.count - 1]
            func crossings(_ p: [Point]) -> Int { routed.map { index in zip(p, p.dropFirst()).reduce(0) { $0 + index.crossings($1.0, $1.1) } } ?? 0 }
            for k in 1..<path.count - 1 {
                let corner = path[k], mine = Bend(corner: corner, toward: path[k - 1] - corner, away: path[k + 1] - corner)
                let count = corners[corner, default: []].filter { !$0.runsWith(mine) }.count
                guard count > 0 else { continue }
                let a = path[k - 1] - corner, b = path[k + 1] - corner
                guard a.length > 0, b.length > 0 else { continue }
                let inward = a / a.length + b / b.length
                guard inward.length > 1e-9 else { continue }
                let outward = inward / -inward.length, crossed = crossings(path)
                for n in stride(from: count, through: 1, by: -1) {
                    var trial = path; trial[k] = corner + outward * (step * Double(n))
                    if relevant(ObstaclePolyline.bounds(trial).inflated(by: gap), edge, start, end).allSatisfy({ i in
                        let probe = ObstaclePolyline.probe(rects[i], start, end, gap, straight: true)
                        return !zip(trial, trial.dropFirst()).contains { probe.intersectsLine($0, $1) }
                    }) && crossings(trial) <= crossed { path = trial; break }
                }
            }
            return path
        }
    }

    /// An edge bending at a padded corner, by the directions it comes from and leaves towards.
    struct Bend: Equatable {
        var corner: Point, toward: Point, away: Point
        /// Whether `other` arrives and leaves the same way (or the reverse), so a separator lane rather than a corner offset serves it.
        func runsWith(_ other: Bend) -> Bool {
            func close(_ a: Point, _ b: Point) -> Bool {
                abs(a.x * b.y - a.y * b.x) <= sin(5 * Double.pi / 180) * a.length * b.length && a.x * b.x + a.y * b.y > 0
            }
            return close(toward, other.toward) && close(away, other.away) || close(toward, other.away) && close(away, other.toward)
        }
    }

    /// Routed segments by owning edge, queried for how many a candidate segment properly crosses.
    final class SegmentIndex {
        private var segments: [(a: Point, b: Point, owner: Int)] = []
        private var removed = Set<Int>()
        private let tree: QuadTree<Int>
        init(bounds: Rect) { tree = QuadTree<Int>(bounds: bounds.inflated(by: max(bounds.width, bounds.height))) }
        func add(_ path: [Point], owner: Int) {
            for (a, b) in zip(path, path.dropFirst()) {
                tree.insert(bounds: ObstaclePolyline.bounds([a, b]).inflated(by: 1e-3), item: segments.count); segments.append((a, b, owner))
            }
        }
        func remove(owner: Int) { for (i, s) in segments.enumerated() where s.owner == owner { removed.insert(i) } }
        func crossings(_ a: Point, _ b: Point) -> Int {
            func side(_ p: Point, _ q: Point, _ r: Point) -> Double { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
            return tree.query(ObstaclePolyline.bounds([a, b]).inflated(by: 1e-3)).reduce(0) { count, i in
                guard !removed.contains(i) else { return count }
                let (c, d, _) = segments[i]
                let d1 = side(a, b, c), d2 = side(a, b, d), d3 = side(c, d, a), d4 = side(c, d, b)
                return count + (d1 * d2 < -1e-9 && d3 * d4 < -1e-9 ? 1 : 0)
            }
        }
    }
    /// The detour search's own measure of a path: length, bends and crossings.
    static func cost(_ path: [Point], bend: Double, crossing: Double, routed: SegmentIndex) -> Double {
        var total = 0.0
        for (k, (a, b)) in zip(path, path.dropFirst()).enumerated() {
            total += (b - a).length + crossing * Double(routed.crossings(a, b))
            if bend > 0, k > 0 { total += bend * turn(path[k - 1], a, b) / .pi }
        }
        return total
    }
    static func turn(_ a: Point, _ b: Point, _ c: Point) -> Double {
        let u = b - a, v = c - b
        return atan2(abs(u.x * v.y - u.y * v.x), u.x * v.x + u.y * v.y)
    }

    static func bounds(_ path: [Point]) -> Rect {
        let xs = path.map(\.x), ys = path.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return Rect() }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    static func obstacles(_ edge: LayoutEdge, _ graph: LayoutGraph) -> [Rect] {
        graph.nodes.filter {
            $0 !== edge.source && $0 !== edge.target &&
            !($0.isGroup && (isAncestor($0, of: edge.source) || isAncestor($0, of: edge.target)))
        }.map(\.bounds).filter { $0.width > 0 && $0.height > 0 }
    }
    static func clear(_ path: [Point], _ obstacles: [Rect]) -> Bool {
        if let compute = RoutingCompute.current { return path.count >= 2 && compute.hits(path, obstacles).isEmpty }
        return path.count >= 2 && !zip(path, path.dropFirst()).contains { a, b in
            obstacles.contains { $0.intersectsLine(a, b) }
        }
    }
    /// Near endpoints a route may need less padding, but never less body clearance.
    private static func clearance(_ r: Rect, _ start: Point, _ end: Point, _ gap: Double) -> Double {
        func distance(_ p: Point) -> Double {
            max(0, max(max(r.left - p.x, p.x - r.right), max(r.top - p.y, p.y - r.bottom)))
        }
        return min(gap, min(distance(start), distance(end)) / 2)
    }
    /// What a route must stay out of: the padded obstacle, or for a straight line half the padding.
    private static func probe(_ r: Rect, _ start: Point, _ end: Point, _ gap: Double, straight: Bool) -> Rect {
        let c = clearance(r, start, end, gap)
        return straight ? r.inflated(by: c / 2) : r.inflated(by: c).inflated(by: -min(1e-7, c / 2))
    }

    /// Shortest path (A* over the visibility graph of padded corners) that keeps the padding clear of `obstacles`.
    /// A straight line needs only half the padding. `bend` charges a half-turn and `extra` a segment; both default to nothing.
    static func search(_ start: Point, _ end: Point, _ obstacles: [Rect], padding: Double, bend: Double = 0,
                       extra: ((Point, Point) -> Double)? = nil) -> [Point]? {
        guard !obstacles.contains(where: { $0.contains(start) || $0.contains(end) }) else { return nil }
        let gap = padding.isFinite ? max(1e-5, padding) : 10
        if clear([start, end], obstacles.map { $0.inflated(by: clearance($0, start, end, gap) / 2) }) { return [start, end] }
        var points = [start, end], seen: Set<Point> = [start, end]
        let expanded = obstacles.map { probe($0, start, end, gap, straight: false) }
        let padded = obstacles.map { $0.inflated(by: clearance($0, start, end, gap)) }
        for r in padded {
            if RoutingCompute.isCancelled { return nil }
            for point in [Point(x: r.left, y: r.top), Point(x: r.right, y: r.top),
                          Point(x: r.right, y: r.bottom), Point(x: r.left, y: r.bottom)] {
                if !expanded.contains(where: { $0.contains(point) }), seen.insert(point).inserted { points.append(point) }
            }
        }
        let tree = QuadTree<Rect>(bounds: expanded.dropFirst().reduce(expanded[0]) { $0.union($1) }.inflated(by: 1))
        for r in expanded { tree.insert(bounds: r, item: r) }
        func visible(_ a: Point, _ b: Point) -> Bool {
            let area = Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).inflated(by: 1e-6)
            return !tree.query(area).contains { $0.intersectsLine(a, b) }
        }
        let heuristic = points.map { ($0 - end).length }
        var cost = Array(repeating: Double.infinity, count: points.count), previous = Array(repeating: -1, count: points.count)
        // Binary min-heap on (estimate, index): the lower index wins ties.
        var heap: [(Double, Int)] = []
        func before(_ a: (Double, Int), _ b: (Double, Int)) -> Bool { a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        func push(_ item: (Double, Int)) {
            heap.append(item); var c = heap.count - 1
            while c > 0, before(heap[c], heap[(c - 1) / 2]) { heap.swapAt(c, (c - 1) / 2); c = (c - 1) / 2 }
        }
        func pop() -> (Double, Int)? {
            guard let top = heap.first else { return nil }
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last; var c = 0
                while true {
                    var m = c
                    for child in [2 * c + 1, 2 * c + 2] where child < heap.count && before(heap[child], heap[m]) { m = child }
                    if m == c { break }
                    heap.swapAt(c, m); c = m
                }
            }
            return top
        }
        cost[0] = 0; push((heuristic[0], 0))
        while let (estimate, current) = pop() {
            if RoutingCompute.isCancelled { return nil }
            if estimate > cost[current] + heuristic[current] + 1e-9 { continue }
            if current == 1 {
                var result = [end], index = 1
                while previous[index] >= 0 { index = previous[index]; result.append(points[index]) }
                return result.reversed()
            }
            for next in points.indices where next != current {
                var candidate = cost[current] + (points[current] - points[next]).length
                guard candidate < cost[next], visible(points[current], points[next]) else { continue }
                if bend > 0, previous[current] >= 0 {
                    candidate += bend * turn(points[previous[current]], points[current], points[next]) / .pi
                }
                if let extra { candidate += extra(points[current], points[next]) }
                if candidate < cost[next] { cost[next] = candidate; previous[next] = current; push((candidate + heuristic[next], next)) }
            }
        }
        return nil
    }

    /// Re-routes every edge (or `edges`) whose path cuts a node, at the router's `padding`. An edge with no clear
    /// route keeps its path, or a straight line if it has none, and is returned so callers can report it. Detoured
    /// edges are then separated by `spacing`.
    @discardableResult
    static func repair(_ graph: LayoutGraph, edges: [LayoutEdge]? = nil, padding: Double = defaultPadding, spacing: Double = 10) -> [LayoutEdge] {
        let scene = Scene(graph.nodes)
        var detoured: [LayoutEdge] = [], failed: [LayoutEdge] = []
        for edge in (edges ?? graph.edges) where edge.source !== edge.target {
            if RoutingCompute.isCancelled { return failed }
            if scene.clear(edge.path, edge) { continue }
            let found = scene.route(edge, padding: padding)
            if RoutingCompute.isCancelled { return failed }
            if let found { edge.path = found.path; detoured.append(edge) }
            else { failed.append(edge); if edge.path.count < 2 { edge.path = [edge.source.center, edge.target.center] } }
        }
        if spacing > 0, detoured.count > 1 {
            let separator = EdgeSeparator(); separator.spacing = spacing; separator.separate(detoured, scene)
        }
        return failed
    }
}
