import Foundation

/// Orthogonal routing on a node-aligned sparse grid with direction-aware costs. Edges leave and enter on a node side
/// (chosen to face the other endpoint unless constrained), start and end on the node boundary perpendicular to it, keep
/// half a `gridSize` clear of other nodes, and never cross an endpoint's interior or a group the edge does not belong
/// to. Routes laid earlier make the spans they use dearer for later ones. Failed searches are retried with less
/// clearance, then drawn as an obstacle-aware polyline or an orthogonal L/Z between side ports; every such edge is
/// reported.
public final class ChannelEdgeRouter: EdgeRouter {
    // MARK: - Nested types

    /// A node side as a search endpoint: the boundary point and the grid vertex straight out from it.
    private struct Port {
        var point: Point
        var entry: Int
        var axis: ChannelGrid.Axis

        /// The span between the entry and the node, which every route through this port uses.
        var stub: Int?
        var cost: Float
    }

    /// A grid with the congestion laid on it and its search storage.
    private struct Pass {
        var grid: ChannelGrid
        var congestion: ChannelCongestion
        let storage: ChannelSearchStorage
    }

    private struct Scene {
        var graph: LayoutGraph
        var leaves: QuadTree<LayoutNode>
        var vertical: Bool

        /// Group nodes with an area, in the order of `ChannelGrid.groups`.
        var groups: [LayoutNode]
    }

    private struct Found {
        var vertices: [Int]
        var start: Port
        var end: Port
    }

    /// One edge's route as drawn so far.
    private struct Placement {
        var path: [Point]

        /// Whether the route lies on the strict grid, where negotiation reroutes it; relaxed and fallback routes stay.
        var isNegotiable: Bool

        /// `ChannelCongestion.sharingCost` of the route when it was laid.
        var paid: Float = 0
    }

    // MARK: - Properties

    /// The grid's unit: port slots and gap subdivisions are this far apart, and routes keep half of it clear of nodes.
    public var gridSize = 20
    public var bendPenalty = 2
    public var congestionPenalty = 2

    /// Negotiated rip-up-and-reroute rounds after the first pass. Each round charges spans still shared by several
    /// routes a lasting history cost, then reroutes every edge whose spans now cost more to share than when it was
    /// laid, longest first; the round with the least sharing is kept. Edges laid early thereby see the ones laid
    /// after them, so the result depends less on `graph.edges` order. 0 routes every edge once, in that order. Needs
    /// a positive `congestionPenalty`.
    public var negotiationRounds = 2

    /// Unroutable edges are those the grid search could not route; each falls back to a polyline, an L/Z or a
    /// straight line, so it is listed under fallbacks too.
    public private(set) var report = RoutingReport()

    /// Edges that the grid search could not route; they fall back to a polyline, an L/Z or a straight line.
    @available(*, deprecated, message: "Use report.unroutable or report.unroutableEdges(in:)")
    public var unroutableEdges: [LayoutEdge] { failed }

    private var failed: [LayoutEdge] = []

    /// The four steps a search may take from a vertex.
    private static let moves: [(ChannelGrid.Axis, Int)] = [
        (.horizontal, 1), (.horizontal, -1), (.vertical, 1), (.vertical, -1),
    ]

    /// Free port lines kept per node side.
    private static let portLines = 5

    /// How far the grid reaches beyond the scene, in grid units: routes may go round the outside of everything.
    private static let margin: Float = 20

    /// Positions in `placements` of the routes drawn at each node, so later ports can avoid crossing them.
    private var attached: [ObjectIdentifier: [Int]] = [:]

    /// Each edge's route by position in `graph.edges`; written to the edges once negotiation is over.
    private var placements: [Placement?] = []

    /// The side and point `PortAssignment` chose for each edge end in this pass; the search prefers them.
    private var assigned = AssignedPorts()

    // MARK: - Init

    public init() {}

    // MARK: - Routing

    public func routeEdges(_ graph: LayoutGraph) {
        failed = []
        attached = [:]
        // Sides and aims come from the shared assignment, but ends sharing a side are not spread before the search:
        // the grid's port slots and the congestion cost already spread them.
        assigned = PortAssignment(edgeSpacing: 0).assign(graph, style: .orthogonal)
        graph.routeStyle = .orthogonal
        report = RoutingReport()
        defer { report = RoutingReport(graph, unroutable: failed, fallbacks: failed) }
        guard !graph.nodes.isEmpty else { return }
        precondition(gridSize > 0, "gridSize must be positive")
        let leaves = QuadTree<LayoutNode>(bounds: enclosingBounds(graph.nodes).inflated(by: 100))
        for n in graph.nodes where !n.isGroup { leaves.insert(bounds: n.bounds, item: n) }
        for group in graph.nodes where group.isGroup {
            if let r = group.groupTitleBounds {
                let header = LayoutNode(id: "header:" + group.id, width: r.width, height: r.height)
                header.bounds = r
                leaves.insert(bounds: r, item: header)
            }
        }
        let scene = Scene(
            graph: graph,
            leaves: leaves,
            vertical: OrthogonalPorts.flow(graph).vertical,
            groups: graph.nodes.filter { $0.isGroup && $0.width > 0 && $0.height > 0 }
        )
        let pitch = Float(gridSize)
        var strict = makePass(scene, clearance: pitch / 2)
        var relaxed: Pass?
        placements = Array(repeating: nil, count: graph.edges.count)
        for (position, edge) in graph.edges.enumerated() where edge.source !== edge.target {
            if RoutingCompute.isCancelled { return }
            LayoutStageScope.tick(position, of: graph.edges.count)
            var placement = route(edge, &strict, scene).map { path in
                let paid = strict.congestion.sharingCost(of: ObjectIdentifier(edge), strict.grid)
                return Placement(path: path, isNegotiable: true, paid: paid)
            }
            if placement == nil {
                if relaxed == nil { relaxed = makePass(scene, clearance: pitch / 8) }
                // `relaxed` was assigned on the line above if it was still nil.
                placement = route(edge, &relaxed!, scene).map { Placement(path: $0, isNegotiable: false) }
            }
            if RoutingCompute.isCancelled { return }
            if placement == nil {
                placement = Placement(path: RoutingFallback.route(edge, graph), isNegotiable: false)
                failed.append(edge)
            }
            place(position, edge, placement)
        }
        negotiate(graph, &strict, scene)
        if RoutingCompute.isCancelled { return }
        for (edge, placement) in zip(graph.edges, placements) {
            if let placement { edge.path = placement.path }
        }
    }

    // MARK: - Negotiation

    /// Rips up and reroutes, in rounds, the strict-grid edges whose spans now cost more to share than when they were
    /// laid: a later route moved onto them, or the round raised their history. The round with the least overuse is
    /// kept. Longer edges are rerouted first, as in `PolylineEdgeRouter`: a short edge gives way more cheaply.
    ///
    /// The first pass keeps `graph.edges` order: sorting it by length makes the result almost independent of that
    /// order, but raised crossings by 6–10% on the 300-edge topology.
    private func negotiate(_ graph: LayoutGraph, _ pass: inout Pass, _ scene: Scene) {
        guard congestionPenalty > 0, negotiationRounds > 0 else { return }
        var best = (overuse: pass.congestion.overuse(pass.grid), placements: placements)
        for _ in 0..<negotiationRounds {
            guard best.overuse > 0 else { break }
            pass.congestion.escalate()
            let risen = placements.indices.filter { i in
                guard let placement = placements[i], placement.isNegotiable else { return false }
                let owner = ObjectIdentifier(graph.edges[i])
                return pass.congestion.sharingCost(of: owner, pass.grid) > placement.paid + 1e-3
            }
            guard !risen.isEmpty else { break }
            func span(_ i: Int) -> Float {
                let d = graph.edges[i].source.center - graph.edges[i].target.center
                return abs(d.x) + abs(d.y)
            }
            for i in risen.sorted(by: { (-span($0), $0) < (-span($1), $1) }) {
                if RoutingCompute.isCancelled { return }
                let edge = graph.edges[i]
                let owner = ObjectIdentifier(edge)
                // `risen` only lists positions with a placement, and a negotiable one has a footprint.
                let old = placements[i]!
                let footprint = pass.congestion.footprint(of: owner)!
                place(i, edge, nil)
                pass.congestion.remove(owner: owner)
                if let path = route(edge, &pass, scene) {
                    let paid = pass.congestion.sharingCost(of: owner, pass.grid)
                    place(i, edge, Placement(path: path, isNegotiable: true, paid: paid))
                } else {
                    pass.congestion.add(footprint, owner: owner)
                    place(i, edge, old)
                }
            }
            let overuse = pass.congestion.overuse(pass.grid)
            if overuse < best.overuse { best = (overuse, placements) }
        }
        placements = best.placements
    }

    /// Records the route of `edge` at `position`, or removes it for `nil`, keeping `attached` in step.
    private func place(_ position: Int, _ edge: LayoutEdge, _ placement: Placement?) {
        for node in [edge.source, edge.target] {
            let key = ObjectIdentifier(node)
            attached[key, default: []].removeAll { $0 == position }
            if placement != nil { attached[key, default: []].append(position) }
        }
        placements[position] = placement
    }

    /// Lines at every node centre and side, the port slots of every edge endpoint, and the straight-through positions
    /// of edges whose ends overlap.
    private func makePass(_ scene: Scene, clearance: Float) -> Pass {
        let graph = scene.graph
        let pitch = Float(gridSize)
        let headers = graph.nodes.compactMap(\.groupTitleBounds)
        let obstacles = graph.nodes.filter { !$0.isGroup }.map(\.bounds) + headers
        var anchors = ChannelGrid.Lines()
        var slots = ChannelGrid.Lines()
        var endpoints = Set<ObjectIdentifier>()
        for edge in graph.edges where edge.source !== edge.target {
            for (node, other) in [(edge.source, edge.target), (edge.target, edge.source)] {
                if endpoints.insert(ObjectIdentifier(node)).inserted {
                    anchors.x.append(node.center.x)
                    anchors.y.append(node.center.y)
                    slots.x += Self.slots(node.bounds.left, node.bounds.right, pitch)
                    slots.y += Self.slots(node.bounds.top, node.bounds.bottom, pitch)
                }
                let r = node.bounds
                let o = other.bounds
                if max(r.left, o.left) < min(r.right, o.right) {
                    anchors.x.append(OrthogonalPorts.point(node, side: .top, toward: o).x)
                }
                if max(r.top, o.top) < min(r.bottom, o.bottom) {
                    anchors.y.append(OrthogonalPorts.point(node, side: .left, toward: o).y)
                }
            }
        }
        let grid = ChannelGrid(
            obstacles: obstacles,
            groups: scene.groups.map(\.bounds),
            anchors: anchors,
            slots: slots,
            pitch: pitch,
            clearance: clearance,
            margin: Self.margin * pitch
        )
        return Pass(
            grid: grid,
            congestion: ChannelCongestion(grid, penalty: congestionPenalty),
            storage: ChannelSearchStorage(states: grid.vertexCount * 2)
        )
    }

    /// Positions a pitch apart along a side, centred on it and kept off the corners by the port inset.
    private static func slots(_ low: Float, _ high: Float, _ pitch: Float) -> [Float] {
        let inset = min(PortAssignment.defaultInset, (high - low) / 4)
        let centre = (low + high) / 2
        let reach = max(0, (high - low) / 2 - inset)
        let count = Int(reach / pitch)
        return (-count...count).map { centre + Float($0) * pitch }
    }

    private func route(_ edge: LayoutEdge, _ pass: inout Pass, _ scene: Scene) -> [Point]? {
        let s = edge.source
        let t = edge.target
        if isAncestor(s, of: t) || isAncestor(t, of: s) { return nil }
        // Groups are walls except those the edge starts or ends inside; an endpoint group's interior is never passable.
        let walls = scene.groups.indices.filter { i in
            let group = scene.groups[i]
            return group === s || group === t || !(isAncestor(group, of: s) || isAncestor(group, of: t))
        }
        let from = assigned.source(of: edge)
        let to = assigned.target(of: edge)
        let starts = ports(s, t, edge.sourcePort, edge.sourcePortCandidates, from, pass, walls, scene)
        let ends = ports(t, s, edge.targetPort, edge.targetPortCandidates, to, pass, walls, scene)
        guard !starts.isEmpty, !ends.isEmpty else { return nil }
        guard let found = search(starts, ends, pass, walls) else { return nil }
        pass.congestion.add(footprint(found, pass.grid), owner: ObjectIdentifier(edge))
        let points = [found.start.point] + found.vertices.map(pass.grid.point) + [found.end.point]
        return simplify(points)
    }

    // MARK: - Ports

    /// Per side, the grid lines crossing it nearest the point level with the other node, so edges sharing a side can
    /// spread out instead of stacking on one point. The assigned port's side ranks first and its point is the one aimed
    /// at; the other sides stay as fallbacks.
    private func ports(
        _ node: LayoutNode,
        _ other: LayoutNode,
        _ active: PortConstraint,
        _ candidates: [PortConstraint],
        _ port: EdgePort?,
        _ pass: Pass,
        _ walls: [Int],
        _ scene: Scene
    ) -> [Port] {
        let grid = pass.grid
        var sides = OrthogonalPorts.ranked(
            node,
            other: other,
            active: active,
            candidates: candidates,
            vertical: scene.vertical
        )
        if let port, let i = sides.firstIndex(of: port.side) { sides.insert(sides.remove(at: i), at: 0) }
        let r = node.bounds
        let pitch = grid.pitch
        let routes = (attached[ObjectIdentifier(node)] ?? []).compactMap { placements[$0]?.path }
        var result: [Port] = []
        for (rank, side) in sides.enumerated() {
            let vertical = OrthogonalPorts.isVertical(side)
            // Ports on the top and bottom sit on x lines and leave vertically; on the left and right, the reverse.
            let along: ChannelGrid.Axis = vertical ? .horizontal : .vertical
            let stubAxis = along.other
            let raw =
                port.flatMap { $0.side == side ? $0.point : nil }
                ?? OrthogonalPorts.point(node, side: side, toward: other.bounds)
            let rawValue = vertical ? raw.x : raw.y
            let lo = vertical ? r.left : r.top
            let hi = vertical ? r.right : r.bottom
            let span = PortAssignment.span(of: r, side: side)
            let exit: Float
            switch side {
            case .top: exit = r.top - grid.clearance
            case .bottom: exit = r.bottom + grid.clearance
            case .left: exit = r.left - grid.clearance
            default: exit = r.right + grid.clearance
            }
            guard let exitLine = grid.line(at: exit, axis: stubAxis) else {
                continue
            }
            var lines = Array(grid.lines(in: span.low...max(span.low, span.high), axis: along))
            if lines.isEmpty { lines = Array(grid.lines(in: lo...hi, axis: along)) }
            let coordinates = along == .horizontal ? grid.xs : grid.ys
            // Every line is a candidate, nearest first: a blocked neighbourhood must not hide a free line further along
            // the side.
            lines.sort { (abs(coordinates[$0] - rawValue), $0) < (abs(coordinates[$1] - rawValue), $1) }
            var accepted = 0
            for k in lines {
                if accepted >= Self.portLines { break }
                let value = coordinates[k]
                let entry =
                    along == .horizontal ? grid.vertex(column: k, row: exitLine) : grid.vertex(column: exitLine, row: k)
                if grid.isBlocked(entry, walls: walls) { continue }
                let p = vertical ? Point(x: value, y: raw.y) : Point(x: raw.x, y: value)
                let tip = grid.point(entry)
                let hit = scene.leaves
                    .query(
                        Rect(x: min(p.x, tip.x), y: min(p.y, tip.y), width: abs(p.x - tip.x), height: abs(p.y - tip.y))
                            .inflated(by: 0.5)
                    )
                    .contains { $0 !== node && $0.bounds.intersectsLine(p, tip) }
                if hit || (other.isGroup && other.bounds.intersectsLine(p, tip)) { continue }
                // The stub is the span from the entry back towards the node. A node too small to have a line inside it
                // (only possible at extreme coordinates) has none, and its ports go uncounted.
                let inward = side == .top || side == .left ? 1 : -1
                let stub = grid.neighbour(of: entry, along: stubAxis, step: inward)
                    .map { ChannelGrid.span(between: entry, $0, along: stubAxis) }
                // Each crossing of a route already at this node costs a quarter bend, like a side rank: more drives
                // routes round the long way. It is judged on the likely route: out along the stub, level with the
                // other node, then in.
                let guess = [
                    p, tip, vertical ? Point(x: other.center.x, y: tip.y) : Point(x: tip.x, y: other.center.y),
                    other.center,
                ]
                let cost =
                    Float(rank * bendPenalty) / 4 + 0.25 * abs(value - rawValue) / pitch
                    + (stub.map { pass.congestion.cost(along: $0, length: pitch) } ?? 0)
                    + pass.congestion.crossingCost(at: entry, along: stubAxis)
                    + Float(bendPenalty) / 4 * Float(Self.crossings(guess, routes))
                result.append(Port(point: p, entry: entry, axis: stubAxis, stub: stub, cost: cost))
                accepted += 1
            }
        }
        return result
    }

    private static func crossings(_ path: [Point], _ routes: [[Point]]) -> Int {
        func cross(_ a: Point, _ b: Point) -> Float { a.x * b.y - a.y * b.x }
        var count = 0
        for (a, b) in zip(path, path.dropFirst()) {
            for route in routes {
                for (c, d) in zip(route, route.dropFirst()) {
                    let u = b - a
                    let v = d - c
                    let denominator = cross(u, v)
                    guard abs(denominator) > 1e-6 else { continue }
                    let t = cross(c - a, v) / denominator
                    let s = cross(c - a, u) / denominator
                    if t > 1e-5 && t < 1 - 1e-5 && s > 1e-5 && s < 1 - 1e-5 { count += 1 }
                }
            }
        }
        return count
    }

    // MARK: - Search

    /// A* over (vertex, axis of arrival) states. A step goes to the next line in one of four directions and costs its
    /// length in grid units, a bend penalty when it turns, and the congestion of the span and vertex it uses.
    private func search(
        _ starts: [Port],
        _ ends: [Port],
        _ pass: Pass,
        _ walls: [Int]
    ) -> Found? {
        let grid = pass.grid
        let congestion = pass.congestion
        let storage = pass.storage.begin()
        let xs = grid.xs
        let ys = grid.ys
        let columns = grid.columns
        let rows = grid.rows
        let scale = 1 / grid.pitch
        let bend = Float(bendPenalty)
        let isCongested = !congestion.isEmpty
        var goals: [Int: Port] = [:]
        for e in ends where goals[e.entry].map({ e.cost < $0.cost }) ?? true { goals[e.entry] = e }
        let goalVertices = Array(goals.keys)
        // Distance to the box around the goal entries, the cheapest goal port, and a bend wherever one is unavoidable:
        // still never an overestimate, and much tighter than distance alone once routes turn corners.
        let targets = ends.map { grid.point($0.entry) }
        let low = Point(x: targets.map(\.x).min() ?? 0, y: targets.map(\.y).min() ?? 0)
        let high = Point(x: targets.map(\.x).max() ?? 0, y: targets.map(\.y).max() ?? 0)
        let cheapest = ends.map(\.cost).min() ?? 0
        @inline(__always) func heuristic(_ x: Float, _ y: Float, _ axis: ChannelGrid.Axis) -> Float {
            let dx = max(low.x - x, 0, x - high.x)
            let dy = max(low.y - y, 0, y - high.y)
            let turns = dx > 0 && (dy > 0 || axis == .vertical) || dy > 0 && axis == .horizontal
            return (dx + dy) * scale + cheapest + (turns ? bend : 0)
        }
        let cells = grid.cells
        let (mask, unmarked) = grid.mask(walls: walls)
        var sources: [Int: Port] = [:]
        var queue = RoutingPriorityQueue<Int>()
        for port in starts {
            let state = port.entry * 2 + port.axis.rawValue
            guard port.cost < storage.cost(state) else { continue }
            sources[state] = port
            storage.update(state, cost: port.cost, previous: -1)
            let p = grid.point(port.entry)
            queue.push(state, priority: port.cost + heuristic(p.x, p.y, port.axis))
        }
        var best: (cost: Float, state: Int, goal: Port)?
        var pops = 0
        while let current = queue.pop() {
            // Reading the task-local cancellation state costs more than a pop; check it in batches.
            pops &+= 1
            if pops & 255 == 0 && RoutingCompute.isCancelled { return nil }
            if storage.isClosed(current) { continue }
            storage.close(current)
            let vertex = current / 2
            let c = vertex % columns
            let r = vertex / columns
            let g = storage.cost(current)
            // Its twin may have become a bend or more cheaper since this state was queued.
            if storage.cost(current ^ 1) + bend <= g { continue }
            let axis: ChannelGrid.Axis = current & 1 == 0 ? .horizontal : .vertical
            if let best, g + heuristic(xs[c], ys[r], axis) >= best.cost { break }
            if goalVertices.contains(vertex), let goal = goals[vertex] {
                let total = g + goal.cost + (axis != goal.axis ? bend : 0)
                if best.map({ total < $0.cost }) ?? true { best = (total, current, goal) }
            }
            for (direction, step) in Self.moves {
                let horizontal = direction == .horizontal
                let nc = horizontal ? c + step : c
                let nr = horizontal ? r : r + step
                guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                let next = nr * columns + nc
                let state = next * 2 + direction.rawValue
                if storage.isClosed(state) { continue }
                if let cells {
                    if cells[next] & mask != 0 { continue }
                } else if grid.isBlocked(column: nc, row: nr) {
                    continue
                }
                if !unmarked.isEmpty && unmarked.contains(where: { $0.contains(column: nc, row: nr) }) { continue }
                let nx = xs[nc]
                let ny = ys[nr]
                let length = abs(nx - xs[c]) + abs(ny - ys[r])
                var cost = g + length * scale + (direction != axis ? bend : 0)
                if isCongested {
                    let span = ChannelGrid.span(from: min(vertex, next), along: direction)
                    cost +=
                        congestion.cost(along: span, length: length)
                        + congestion.crossingCost(at: next, along: direction)
                }
                // From here on the two states of a vertex differ only by the bend one of them takes to turn, so a
                // state at least a bend dearer than its twin can never lead anywhere cheaper.
                guard cost < storage.cost(state), cost < storage.cost(state ^ 1) + bend else { continue }
                storage.update(state, cost: cost, previous: current)
                // Ties go to the state nearer the goal, so open ground is crossed in a line, not a diamond.
                queue.push(state, priority: cost + heuristic(nx, ny, direction) * 1.001)
            }
        }
        guard let best else { return nil }
        var states: [Int] = []
        var state = best.state
        while state >= 0 {
            states.append(state)
            state = storage.previous(state)
        }
        states.reverse()
        // The first state was pushed from a port, so it is in `sources`.
        guard let start = sources[states[0]] else { preconditionFailure("Channel search began outside its ports") }
        return Found(vertices: states.map { $0 / 2 }, start: start, end: best.goal)
    }

    /// The spans and vertex passes a found route occupies, its port stubs included.
    private func footprint(_ found: Found, _ grid: ChannelGrid) -> ChannelCongestion.Footprint {
        var footprint = ChannelCongestion.Footprint(spans: [found.start.stub, found.end.stub].compactMap { $0 })
        let vertices = found.vertices
        var arriving = found.start.axis
        for (i, vertex) in vertices.enumerated() {
            let leaving: ChannelGrid.Axis
            if i + 1 < vertices.count {
                let next = vertices[i + 1]
                leaving = grid.row(next) == grid.row(vertex) ? .horizontal : .vertical
                footprint.spans.append(ChannelGrid.span(between: vertex, next, along: leaving))
            } else {
                leaving = found.end.axis
            }
            footprint.passes.append(vertex * 2 + arriving.rawValue)
            if leaving != arriving { footprint.passes.append(vertex * 2 + leaving.rawValue) }
            arriving = leaving
        }
        return footprint
    }

    /// Drops repeated points and the middle of straight runs.
    private func simplify(_ points: [Point]) -> [Point] {
        var path = points
        if path.count >= 3 {
            for i in stride(from: path.count - 2, through: 1, by: -1) {
                let a = path[i] - path[i - 1]
                let b = path[i + 1] - path[i]
                if abs(a.x * b.y - a.y * b.x) <= 0.001 { path.remove(at: i) }
            }
        }
        return path
    }
}
