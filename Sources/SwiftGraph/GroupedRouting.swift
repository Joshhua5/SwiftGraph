import Foundation

/// Hierarchical channel routing: lanes run between obstacles and `obstacleMargin` outside their outlines, edges may
/// only cross the groups they start or end in, and the root frame is `obstacleMargin` clear of the outermost nodes.
/// Source and target port constraints and candidates choose the side an edge leaves and enters. Shared corridors are
/// first widened by safely nudging nodes (kept inside their group, clear of other routes), then separated with
/// `EdgeSeparator`. Edges the channels cannot route are retried over a flat grid, then drawn as an obstacle-aware
/// polyline or an orthogonal L/Z, and reported.
public final class OrthogonalGroupedEdgeRouter: EdgeRouter {
    /// Lane spacing for edges sharing a corridor; 0 leaves them merged and disables nudging.
    public var bundleSpacing: Float = 10
    public var obstacleMargin: Float = 10
    public var bendPenalty: Float = 100
    /// Edges the channels and the flat retry could not route; they are drawn as a polyline, an L/Z or a straight line.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    private let calculator = ChannelGridCalculator(), flatCalculator = ChannelGridCalculator()
    private var flatRoot: LayoutNode?
    public init() {}

    public func routeEdges(_ graph: LayoutGraph) {
        unroutableEdges = []
        guard !graph.edges.isEmpty else { return }
        if !graph.root.children.isEmpty { graph.root.bounds = enclosingBounds(graph.root.children).inflated(by: obstacleMargin * 2) }
        rebuild(graph)
        var paths: [LayoutEdge: [Point]] = [:]
        let edges = graph.edges.filter { $0.source !== $0.target }
        for edge in edges {
            if RoutingCompute.isCancelled { return }
            let path = solve(edge, graph); edge.path = path; paths[edge] = path
        }
        if bundleSpacing > 0 { nudge(graph, edges: edges, paths: &paths) }
        if RoutingCompute.isCancelled { return }
        EdgeEndpointClipper.clipToNodeBounds(graph)
        if bundleSpacing > 0 {
            let separator = EdgeSeparator(); separator.spacing = bundleSpacing; separator.routeEdges(graph)
        }
    }
    private func rebuild(_ graph: LayoutGraph) {
        calculator.margin = obstacleMargin; calculator.buildChannels(graph.root)
        flatRoot = nil
    }
    /// A synthetic group holding every leaf, for the flat retry; built on first use.
    private func flat(_ graph: LayoutGraph) -> LayoutNode {
        if let flatRoot { return flatRoot }
        let leaves = graph.nodes.filter { !$0.isGroup }, node = LayoutNode(id: "flat", width: 0, height: 0)
        node.isGroup = true; node.children = leaves
        if !leaves.isEmpty { node.bounds = enclosingBounds(leaves).inflated(by: obstacleMargin * 2) }
        flatCalculator.margin = obstacleMargin; flatCalculator.buildChannels(node); flatRoot = node
        return node
    }
    private func solve(_ edge: LayoutEdge, _ graph: LayoutGraph) -> [Point] {
        unroutableEdges.removeAll { $0 === edge }
        // Nodes that substantially overlap leave no route between them; a closed loop would be worse than the fallback.
        if Self.overlapsSubstantially(edge.source.bounds, edge.target.bounds) {
            unroutableEdges.append(edge)
            let path = RoutingFallback.route(edge, graph), shared = Self.overlap(edge.source.bounds, edge.target.bounds)
            return path.count >= 2 && path.first != path.last ? path : [Point(x: shared.left, y: shared.center.y), Point(x: shared.right, y: shared.center.y)]
        }
        // On big drawings try a window round the endpoints first: most routes stay local, and the search cost follows.
        let window = graph.nodes.count > 120 ? edge.source.bounds.union(edge.target.bounds).inflated(by: 200 + 2 * obstacleMargin) : nil
        if let path = (window.flatMap { route(edge, graph, flat: false, window: $0) }) ?? route(edge, graph, flat: false) ?? route(edge, graph, flat: true) { return path }
        if RoutingCompute.isCancelled { return edge.path }
        unroutableEdges.append(edge)
        return RoutingFallback.route(edge, graph)
    }
    private static func overlap(_ a: Rect, _ b: Rect) -> Rect {
        Rect(x: max(a.left, b.left), y: max(a.top, b.top), width: max(0, min(a.right, b.right) - max(a.left, b.left)), height: max(0, min(a.bottom, b.bottom) - max(a.top, b.top)))
    }
    private static func overlapsSubstantially(_ a: Rect, _ b: Rect) -> Bool {
        let shared = overlap(a, b)
        return shared.width > 0 && shared.height > 0 && shared.width * shared.height > 0.25 * min(a.width * a.height, b.width * b.height)
    }
    private func ancestors(_ node: LayoutNode) -> [LayoutNode] {
        var result: [LayoutNode] = [], seen = Set<LayoutNode>(), current: LayoutNode? = node
        while let n = current, seen.insert(n).inserted { result.append(n); current = n.parent }
        return result
    }
    private func lowerBound(_ list: [Int], _ value: Int) -> Int {
        var low = 0, high = list.count
        while low < high { let mid = (low + high) / 2; if list[mid] < value { low = mid + 1 } else { high = mid } }
        return low
    }
    /// Directions 1...4 are left, right, up, down; the first move leaves through an allowed side and the last enters through one.
    private static func directions(_ active: PortConstraint, _ candidates: [PortConstraint], inward: Bool) -> Set<Int> {
        let sides = active != .none ? [active] : candidates.filter { $0 != .none }
        func direction(_ side: PortConstraint) -> Int {
            switch side { case .left: inward ? 2 : 1; case .right: inward ? 1 : 2; case .top: inward ? 4 : 3; default: inward ? 3 : 4 }
        }
        return sides.isEmpty ? [1, 2, 3, 4] : Set(sides.map(direction))
    }
    private func route(_ edge: LayoutEdge, _ graph: LayoutGraph, flat isFlat: Bool, window: Rect? = nil) -> [Point]? {
        let source = edge.source, target = edge.target
        let sx = Int(source.center.x), sy = Int(source.center.y), ex = Int(target.center.x), ey = Int(target.center.y)
        var xs: Set<Int> = [sx, ex], ys: Set<Int> = [sy, ey]
        let hierarchy = isFlat ? [flat(graph)] : ancestors(source) + ancestors(target), grids = isFlat ? flatCalculator : calculator
        // Inside a window, only coordinates in it become lanes and vertices; spans reaching past it clamp to its ends.
        func inX(_ v: Int) -> Bool { window.map { Float(v) >= $0.left && Float(v) <= $0.right } ?? true }
        func inY(_ v: Int) -> Bool { window.map { Float(v) >= $0.top && Float(v) <= $0.bottom } ?? true }
        func kids(_ n: LayoutNode) -> [LayoutNode] { window.map { w in n.children.filter { $0.bounds.intersects(w) } } ?? n.children }
        for n in hierarchy + [source, target] {
            let grid = grids.getGrid(n)
            xs.formUnion(grid.xChannels.filter(inX)); ys.formUnion(grid.yChannels.filter(inY))
            xs.formUnion([Int(n.x), Int(n.bounds.right)].filter(inX)); ys.formUnion([Int(n.y), Int(n.bounds.bottom)].filter(inY))
            // Obstacle outlines are vertices even when no lane runs along them, so blocked spans map onto the grid.
            for c in kids(n) { xs.formUnion([Int(c.x), Int(c.bounds.right)].filter(inX)); ys.formUnion([Int(c.y), Int(c.bounds.bottom)].filter(inY)) }
        }
        let xGrid = xs.sorted(), yGrid = ys.sorted(), width = xs.count, height = ys.count
        // With a margin, a lane on another node's outline is as blocked as one through it.
        let closed = obstacleMargin > 0
        var horizontal = RoutingBitSet(count: width * height), vertical = RoutingBitSet(count: width * height)
        for n in hierarchy {
            var grid = grids.getGrid(n)
            // Each endpoint's centre lines are lanes in its own group, so a route can run straight out of the node.
            for (endpoint, cx, cy) in [(source, sx, sy), (target, ex, ey)] where n === (isFlat ? n : endpoint.parent) { grid.xChannels.append(cx); grid.yChannels.append(cy) }
            grid.xChannels = grid.xChannels.filter(inX); grid.yChannels = grid.yChannels.filter(inY)
            let children = kids(n)
            let xStart = lowerBound(xGrid, Int(n.x)), xEnd = lowerBound(xGrid, Int(n.bounds.right))
            let yStart = lowerBound(yGrid, Int(n.y)), yEnd = lowerBound(yGrid, Int(n.bounds.bottom))
            let useMetalBlockers = RoutingCompute.current.map { $0.stages.isEmpty || (grid.xChannels.count + grid.yChannels.count) * children.count >= 1024 } ?? false
            let xBlockers = useMetalBlockers ? RoutingCompute.current?.axisBlockers(grid.xChannels.map(Float.init), rectangles: children.map(\.bounds), vertical: true, closed: closed) : nil
            let yBlockers = useMetalBlockers ? RoutingCompute.current?.axisBlockers(grid.yChannels.map(Float.init), rectangles: children.map(\.bounds), vertical: false, closed: closed) : nil
            for (i, x) in grid.xChannels.enumerated() {
                let ix = lowerBound(xGrid, x)
                let blockers = xBlockers?[i].map { children[$0] } ?? children.filter { closed ? $0.x <= Float(x) && Float(x) <= $0.bounds.right : $0.x < Float(x) && Float(x) < $0.bounds.right }
                let blocked = blockers.map { (lowerBound(yGrid, Int($0.y)), lowerBound(yGrid, Int($0.bounds.bottom))) }
                if yStart < yEnd { for y in yStart..<yEnd where !blocked.contains(where: { y >= $0.0 && y < $0.1 }) { vertical.insert(y * width + ix) } }
            }
            for (i, y) in grid.yChannels.enumerated() {
                let iy = lowerBound(yGrid, y)
                let blockers = yBlockers?[i].map { children[$0] } ?? children.filter { closed ? $0.y <= Float(y) && Float(y) <= $0.bounds.bottom : $0.y < Float(y) && Float(y) < $0.bounds.bottom }
                let blocked = blockers.map { (lowerBound(xGrid, Int($0.x)), lowerBound(xGrid, Int($0.bounds.right))) }
                if xStart < xEnd { for x in xStart..<xEnd where !blocked.contains(where: { x >= $0.0 && x < $0.1 }) { horizontal.insert(iy * width + x) } }
            }
        }
        for n in [source, target] {
            let xStart = lowerBound(xGrid, Int(n.x)), xEnd = lowerBound(xGrid, Int(n.bounds.right))
            let yStart = lowerBound(yGrid, Int(n.y)), yEnd = lowerBound(yGrid, Int(n.bounds.bottom))
            // Inside the node only: lanes along its own outline would hug the face instead of leaving it.
            if xStart < xEnd && yStart < yEnd {
                for x in xStart..<xEnd { for y in yStart..<yEnd { if y > yStart { horizontal.insert(y * width + x) }; if x > xStart { vertical.insert(y * width + x) } } }
            }
        }
        let leave = Self.directions(edge.sourcePort, edge.sourcePortCandidates, inward: false), enter = Self.directions(edge.targetPort, edge.targetPortCandidates, inward: true)
        func inside(_ r: Rect, _ x: Int, _ y: Int) -> Bool { Float(xGrid[x]) > r.left && Float(xGrid[x]) < r.right && Float(yGrid[y]) > r.top && Float(yGrid[y]) < r.bottom }
        func within(_ r: Rect, _ x: Int, _ y: Int) -> Bool { Float(xGrid[x]) >= r.left && Float(xGrid[x]) <= r.right && Float(yGrid[y]) >= r.top && Float(yGrid[y]) <= r.bottom }
        let sourceBounds = source.bounds, targetBounds = target.bounds
        // States are (vertex, direction 0...4); a route may not turn or reverse inside an endpoint. It starts at any lane
        // vertex inside the source (preferring the centre) and ends at the first lane vertex on the target entered inward;
        // exit and entry lanes keep a quarter of the shorter side clear of the corners.
        let sourceInset = min(sourceBounds.width, sourceBounds.height) / 4, targetInset = min(targetBounds.width, targetBounds.height) / 4
        func px(_ x: Int) -> Float { Float(xGrid[x]) }
        func py(_ y: Int) -> Float { Float(yGrid[y]) }
        // Distance to the target rectangle, plus the bend any route from here still needs (off both axes, or heading along the wrong one).
        func heuristic(_ x: Int, _ y: Int, axis: Int) -> Float {
            let dx = max(0, targetBounds.left - px(x), px(x) - targetBounds.right), dy = max(0, targetBounds.top - py(y), py(y) - targetBounds.bottom)
            let turn = dx > 0 && dy > 0 || (dx == 0 && dy > 0 && axis == 0) || (dy == 0 && dx > 0 && axis == 1)
            return dx + dy + (turn ? bendPenalty : 0)
        }
        func accepts(_ x: Int, _ y: Int, _ direction: Int) -> Bool {
            guard enter.contains(direction), targetBounds.contains(Point(x: px(x), y: py(y))) else { return false }
            return direction <= 2 ? py(y) >= targetBounds.top + targetInset && py(y) <= targetBounds.bottom - targetInset : px(x) >= targetBounds.left + targetInset && px(x) <= targetBounds.right - targetInset
        }
        // Sparse search state: a route only visits a sliver of the (lanes x lanes x 5) space.
        var queue = RoutingPriorityQueue<Int>(), costs: [Int: Float] = [:], previous: [Int: Int] = [:], closedStates = Set<Int>()
        let centre = source.center
        for y in max(0, lowerBound(yGrid, Int(sourceBounds.top.rounded(.down))) - 1)..<min(height, lowerBound(yGrid, Int(sourceBounds.bottom.rounded(.up))) + 1) {
            for x in max(0, lowerBound(xGrid, Int(sourceBounds.left.rounded(.down))) - 1)..<min(width, lowerBound(xGrid, Int(sourceBounds.right.rounded(.up))) + 1) where inside(sourceBounds, x, y) {
                if let window, !window.contains(Point(x: px(x), y: py(y))) { continue }
                let state = (y * width + x) * 5, cost: Float = 0.01 * (abs(px(x) - centre.x) + abs(py(y) - centre.y))
                costs[state] = cost; queue.push(state, priority: cost + heuristic(x, y, axis: 2))
            }
        }
        let moves = [(-1, 0, 1), (1, 0, 2), (0, -1, 3), (0, 1, 4)]
        while let current = queue.pop() {
            if RoutingCompute.isCancelled { return nil }
            if !closedStates.insert(current).inserted { continue }
            let direction = current % 5, cell = current / 5, y = cell / width, x = cell % width
            if direction != 0 && accepts(x, y, direction) {
                var i = current, path: [Point] = []
                while true { let c = i / 5; path.append(Point(x: Float(xGrid[c % width]), y: Float(yGrid[c / width]))); guard let p = previous[i] else { break }; i = p }
                path.reverse(); return simplify(path)
            }
            let confined = direction != 0 && (within(sourceBounds, x, y) || within(targetBounds, x, y))
            for (dx, dy, dir) in moves {
                let sameAxis = direction != 0 && (dir - 1) / 2 == (direction - 1) / 2
                if direction == 0 { if !leave.contains(dir) { continue } } else if confined ? dir != direction : sameAxis && dir != direction { continue }
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                // Leaving the source, the exit lane stays clear of its corners.
                if direction == 0 {
                    let lane = dx == 0 ? px(x) : py(y), low = dx == 0 ? sourceBounds.left : sourceBounds.top, high = dx == 0 ? sourceBounds.right : sourceBounds.bottom
                    if lane < low + sourceInset || lane > high - sourceInset { continue }
                }
                if let window, !window.contains(Point(x: Float(xGrid[nx]), y: Float(yGrid[ny]))) { continue }
                let passable = dy == 0 ? horizontal.contains(y * width + min(x, nx)) : vertical.contains(min(y, ny) * width + x)
                if !passable { continue }
                let next = (ny * width + nx) * 5 + dir
                let distance = abs(xGrid[nx] - xGrid[x]) + abs(yGrid[ny] - yGrid[y])
                let bend = direction != 0 && (dir - 1) / 2 != (direction - 1) / 2
                let cost = costs[current]! + Float(distance) + (bend ? bendPenalty : 0)
                if !closedStates.contains(next) && cost < costs[next, default: .infinity] {
                    costs[next] = cost; previous[next] = current
                    queue.push(next, priority: cost + heuristic(nx, ny, axis: (dir - 1) / 2))
                }
            }
        }
        return nil
    }
    private func simplify(_ points: [Point]) -> [Point] {
        guard points.count >= 3 else { return points }
        var result = [points[0]]
        for i in 1..<(points.count - 1) {
            let a = result.last!, b = points[i], c = points[i + 1]
            let sameX = abs(a.x - b.x) < 0.001 && abs(b.x - c.x) < 0.001
            let sameY = abs(a.y - b.y) < 0.001 && abs(b.y - c.y) < 0.001
            if !sameX && !sameY { result.append(b) }
        }
        result.append(points.last!); return result
    }
    private struct Segment: Hashable {
        var a: Point; var b: Point
        init(_ a: Point, _ b: Point) { if Self.reversed(a, b) { self.a = b; self.b = a } else { self.a = a; self.b = b } }
        static func reversed(_ a: Point, _ b: Point) -> Bool { a.x > b.x || (a.x == b.x && a.y > b.y) }
    }
    /// Makes room for shared corridors by moving the nodes that crowd them. A node only moves if it stays inside its
    /// group, clear of every other node, group and unrelated route; channels are rebuilt afterwards and every edge
    /// that touches a moved node, or whose route now meets one, is routed again.
    private func nudge(_ graph: LayoutGraph, edges: [LayoutEdge], paths: inout [LayoutEdge: [Point]]) {
        var counts: [Segment: Int] = [:], order: [Segment] = []
        for edge in edges {
            let path = paths[edge]!
            for (a, b) in zip(path, path.dropFirst()) {
                let s = Segment(a, b)
                if counts[s] == nil { order.append(s) }; counts[s, default: 0] += 1
            }
        }
        let tree = QuadTree<LayoutNode>(bounds: enclosingBounds(graph.nodes).inflated(by: 100))
        var stack = [graph.root], visited = Set<LayoutNode>(), moved = Set<LayoutNode>()
        while let n = stack.popLast() {
            if !visited.insert(n).inserted { continue }; tree.insert(bounds: n.bounds, item: n); stack.append(contentsOf: n.children.reversed())
        }
        let groups = graph.nodes.filter(\.isGroup)
        func crossesOtherRoutes(_ node: LayoutNode, _ area: Rect) -> Bool {
            edges.contains { e in
                e.source !== node && e.target !== node && { let p = paths[e]!; return zip(p, p.dropFirst()).contains { area.intersectsLine($0, $1) } }()
            }
        }
        for segment in order where counts[segment]! > 1 {
            let a = segment.a, b = segment.b, half = Float(counts[segment]!) * bundleSpacing / 2
            let vertical = abs(a.x - b.x) < 0.001
            let bus = vertical ? Rect(x: a.x - half - obstacleMargin, y: min(a.y, b.y), width: 2 * (half + obstacleMargin), height: abs(a.y - b.y)) : Rect(x: min(a.x, b.x), y: a.y - half - obstacleMargin, width: abs(a.x - b.x), height: 2 * (half + obstacleMargin))
            for node in tree.query(bus) {
                if node.isGroup || moved.contains(node) || node.bounds.contains(a) || node.bounds.contains(b) { continue }
                let shift: Point
                if vertical { shift = Point(x: node.center.x < a.x ? bus.left - node.bounds.right : bus.right - node.x, y: 0) }
                else { shift = Point(x: 0, y: node.center.y < a.y ? bus.top - node.bounds.bottom : bus.bottom - node.y) }
                let destination = node.bounds.translated(by: shift)
                if let parent = node.parent, parent !== graph.root, !(parent.bounds.left <= destination.left && parent.bounds.right >= destination.right && parent.bounds.top <= destination.top && parent.bounds.bottom >= destination.bottom) { continue }
                if groups.contains(where: { $0 !== graph.root && !isAncestor($0, of: node) && $0.bounds.intersects(destination) }) { continue }
                let nearby = tree.query(destination).filter { $0 !== node && !$0.isGroup }
                if (RoutingCompute.current.map { !$0.intersections(destination, nearby.map(\.bounds)).isEmpty } ?? nearby.contains(where: { $0.bounds.intersects(destination) })) { continue }
                if crossesOtherRoutes(node, destination) { continue }
                node.bounds = destination; moved.insert(node); tree.insert(bounds: node.bounds, item: node)
            }
        }
        guard !moved.isEmpty else { return }
        if !graph.root.children.isEmpty { graph.root.bounds = enclosingBounds(graph.root.children).inflated(by: obstacleMargin * 2) }
        rebuild(graph)
        for edge in edges where moved.contains(edge.source) || moved.contains(edge.target) || moved.contains(where: { n in let p = paths[edge]!; return zip(p, p.dropFirst()).contains { n.bounds.intersectsLine($0, $1) } }) {
            if RoutingCompute.isCancelled { return }
            let path = solve(edge, graph); paths[edge] = path; edge.path = path
        }
    }
}

struct RoutingBitSet {
    private var words: [UInt64]
    init(count: Int) { words = Array(repeating: 0, count: (count + 63) / 64) }
    mutating func insert(_ index: Int) { words[index >> 6] |= UInt64(1) << (index & 63) }
    func contains(_ index: Int) -> Bool { words[index >> 6] & (UInt64(1) << (index & 63)) != 0 }
}
