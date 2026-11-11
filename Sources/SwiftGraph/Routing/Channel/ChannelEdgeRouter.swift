import Foundation

/// Fixed-pitch lattice routing with direction-aware costs. Edges leave and enter on a node side (chosen to face the
/// other endpoint unless constrained), start and end on the node boundary perpendicular to it, and never cross an
/// endpoint's interior or a group the edge does not belong to. Failed searches are retried, then drawn as an
/// obstacle-aware polyline or an orthogonal L/Z between side ports; every such edge is reported.
public final class ChannelEdgeRouter: EdgeRouter {
    public var gridSize = 20
    public var bendPenalty = 2
    public var congestionPenalty = 2

    /// Unroutable edges are those the lattice search could not route; each falls back to a polyline, an L/Z or a
    /// straight line, so it is listed under fallbacks too.
    public private(set) var report = RoutingReport()

    /// Edges that the lattice search could not route; they fall back to a polyline, an L/Z or a straight line.
    @available(*, deprecated, message: "Use report.unroutable or report.unroutableEdges(in:)")
    public var unroutableEdges: [LayoutEdge] { failed }

    private var failed: [LayoutEdge] = []

    public init() {}

    /// Free lattice lines kept per node side.
    private static let portLines = 5

    /// Routes already drawn at each node, so later port lines can avoid crossing them.
    private var attached: [ObjectIdentifier: [[Point]]] = [:]

    private struct Cell: Hashable {
        var x: Int
        var y: Int
    }

    private struct GridRect {
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int

        func contains(_ p: Cell) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
    }

    private struct Usage { var horizontal = 0, vertical = 0 }

    /// Reused indexed search storage: a generation stamp avoids clearing the whole scene for every edge.
    private final class SearchStorage {
        var generation: UInt32 = 0
        var seen: [UInt32]
        var closed: [UInt32]
        var costs: [Float]
        var previous: [Int]

        /// Per cell: the generation whose goal port sits there, and that port's index in the search's `ends`.
        var goalStamp: [UInt32]
        var goal: [Int32]

        init(count: Int, cells: Int) {
            seen = Array(repeating: 0, count: count)
            closed = seen
            costs = Array(repeating: 0, count: count)
            previous = Array(repeating: -1, count: count)
            goalStamp = Array(repeating: 0, count: cells)
            goal = Array(repeating: -1, count: cells)
        }
    }

    private struct IndexedCells {
        var bounds: GridRect
        var width: Int
        var blocked: [Bool]
        var usage: [Usage]
        var search: SearchStorage

        /// Bit k is set where `Lattice.groups[k]` covers the cell; nil past 64 groups, which keeps the rect scan.
        var groupBits: [UInt64]?

        func index(_ c: Cell) -> Int? {
            guard bounds.contains(c) else { return nil }
            return (c.y - bounds.minY) * width + c.x - bounds.minX
        }

        /// The index of a cell the caller guarantees lies inside `bounds`.
        func requiredIndex(_ c: Cell) -> Int {
            guard let i = index(c) else { preconditionFailure("Cell \(c) lies outside the indexed lattice bounds") }
            return i
        }

        func cell(_ i: Int) -> Cell { Cell(x: bounds.minX + i % width, y: bounds.minY + i / width) }
    }

    /// A node side as a search endpoint: the boundary point, and the first free cell straight out from it.
    private struct Port {
        var point: Point
        var entry: Cell
        var axis: Int
        var cost: Float
    }

    private struct Lattice {
        var grid: Int
        var origin: Point
        var groups: [(node: LayoutNode, rect: GridRect)] = []
        var usage: [Cell: Usage] = [:]
        var indexed: IndexedCells?
        var rectangles: [GridRect] = []

        func isBlocked(_ c: Cell) -> Bool {
            if let indexed, let i = indexed.index(c) { return indexed.blocked[i] }
            return rectangles.contains { $0.contains(c) }
        }

        func usageAt(_ c: Cell) -> Usage? {
            if let indexed, let i = indexed.index(c) { return indexed.usage[i] }
            return usage[c]
        }

        /// Cells covered by any node: beyond it the lattice is empty, so the search only needs a few cells of slack.
        var extent = GridRect(minX: 0, minY: 0, maxX: 0, maxY: 0)

        func cell(_ p: Point) -> Cell {
            Cell(x: Int(floor((p.x - origin.x) / Float(grid))), y: Int(floor((p.y - origin.y) / Float(grid))))
        }

        func centre(_ c: Cell) -> Point {
            Point(x: origin.x + (Float(c.x) + 0.5) * Float(grid), y: origin.y + (Float(c.y) + 0.5) * Float(grid))
        }

        /// Cells a rectangle overlaps; touching a cell boundary (to within `tolerance`) does not occupy the next cell.
        func cover(_ r: Rect) -> GridRect {
            let g = Float(grid)
            let e = Self.tolerance / g
            let minX = Int(floor((r.left - origin.x) / g + e))
            let minY = Int(floor((r.top - origin.y) / g + e))
            return GridRect(
                minX: minX,
                minY: minY,
                maxX: max(minX, Int(ceil((r.right - origin.x) / g - e)) - 1),
                maxY: max(minY, Int(ceil((r.bottom - origin.y) / g - e)) - 1)
            )
        }

        /// Geometry differing by less than this (as GPU layouts do) must not change which cells a node occupies.
        static let tolerance: Float = 0.05
    }

    private struct Scene {
        var graph: LayoutGraph
        var leaves: QuadTree<LayoutNode>
        var vertical: Bool
    }

    public func routeEdges(_ graph: LayoutGraph) {
        failed = []
        attached = [:]
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
        let scene = Scene(graph: graph, leaves: leaves, vertical: OrthogonalPorts.flow(graph).vertical)
        var lattice = makeLattice(graph, grid: gridSize)
        var fine: Lattice?
        for (position, edge) in graph.edges.enumerated() where edge.source !== edge.target {
            if RoutingCompute.isCancelled { return }
            LayoutStageScope.tick(position, of: graph.edges.count)
            var path = route(edge, &lattice, scene, relaxed: false) ?? route(edge, &lattice, scene, relaxed: true)
            if path == nil && gridSize >= 4 {
                if fine == nil { fine = makeLattice(graph, grid: gridSize / 2) }
                // `fine` was assigned on the line above if it was still nil.
                path = route(edge, &fine!, scene, relaxed: true)
            }
            if RoutingCompute.isCancelled { return }
            if path == nil {
                path = RoutingFallback.route(edge, graph)
                failed.append(edge)
            }
            // A nil route was replaced by `RoutingFallback.route`, which always returns a path.
            edge.path = path!
            for node in [edge.source, edge.target] { attached[ObjectIdentifier(node), default: []].append(edge.path) }
        }
    }

    /// Requires a non-empty graph; `routeEdges` returns early for an empty one.
    private func makeLattice(_ graph: LayoutGraph, grid: Int) -> Lattice {
        // `graph.nodes` is non-empty (see above), and so is `covers`, which maps it.
        var lattice = Lattice(
            grid: grid,
            origin: Point(x: graph.nodes.map(\.x).min()! - 50, y: graph.nodes.map(\.y).min()! - 50)
        )
        let headers = graph.nodes.compactMap(\.groupTitleBounds)
        let rectangles = (graph.nodes.filter { !$0.isGroup }.map(\.bounds) + headers).map { lattice.cover($0) }
        lattice.rectangles = rectangles
        let covers = graph.nodes.map { lattice.cover($0.bounds) }
        lattice.extent = GridRect(
            minX: covers.map(\.minX).min()!,
            minY: covers.map(\.minY).min()!,
            maxX: covers.map(\.maxX).max()!,
            maxY: covers.map(\.maxY).max()!
        )
        lattice.groups = graph.nodes.filter { $0.isGroup && $0.width > 0 && $0.height > 0 }
            .map { ($0, lattice.cover($0.bounds)) }
        // The common case fits comfortably in indexed storage. Extremely sparse/large scenes retain the hash search.
        let r = lattice.extent
        let width = r.maxX - r.minX + 41
        let height = r.maxY - r.minY + 41
        if width > 0, height > 0, width <= 1_000_000 / height {
            let fits = rectangles.allSatisfy { r in
                [r.minX, r.minY, r.maxX, r.maxY].allSatisfy { Int32(exactly: $0) != nil }
            }
            let occupied =
                fits
                ? RoutingCompute.current?
                    .occupiedCells(
                        rectangles.map { SIMD4(Int32($0.minX), Int32($0.minY), Int32($0.maxX), Int32($0.maxY)) }
                    ) : nil
            let bounds = GridRect(minX: r.minX - 20, minY: r.minY - 20, maxX: r.maxX + 20, maxY: r.maxY + 20)
            var indexed = IndexedCells(
                bounds: bounds,
                width: width,
                blocked: Array(repeating: false, count: width * height),
                usage: Array(repeating: Usage(), count: width * height),
                search: SearchStorage(count: width * height * 3, cells: width * height)
            )
            if !lattice.groups.isEmpty && lattice.groups.count <= 64 {
                var bits = Array(repeating: UInt64(0), count: width * height)
                for (k, group) in lattice.groups.enumerated() {
                    let r = group.rect
                    let minX = max(r.minX, bounds.minX)
                    let maxX = min(r.maxX, bounds.maxX)
                    let minY = max(r.minY, bounds.minY)
                    let maxY = min(r.maxY, bounds.maxY)
                    guard minX <= maxX, minY <= maxY else { continue }
                    for y in minY...maxY {
                        for x in minX...maxX { bits[indexed.requiredIndex(Cell(x: x, y: y))] |= 1 << UInt64(k) }
                    }
                }
                indexed.groupBits = bits
            }
            if let occupied {
                for cell in occupied {
                    indexed.blocked[indexed.requiredIndex(Cell(x: Int(cell.x), y: Int(cell.y)))] = true
                }
            } else {
                for rect in rectangles {
                    for y in rect.minY...rect.maxY {
                        for x in rect.minX...rect.maxX {
                            indexed.blocked[indexed.requiredIndex(Cell(x: x, y: y))] = true
                        }
                    }
                }
            }
            lattice.indexed = indexed
        }
        return lattice
    }

    private func route(_ edge: LayoutEdge, _ lattice: inout Lattice, _ scene: Scene, relaxed: Bool) -> [Point]? {
        let s = edge.source
        let t = edge.target
        if isAncestor(s, of: t) || isAncestor(t, of: s) { return nil }
        // Groups are walls except those the edge starts or ends inside; an endpoint group's interior is never passable.
        let isWall = lattice.groups.map {
            $0.node === s || $0.node === t || !(isAncestor($0.node, of: s) || isAncestor($0.node, of: t))
        }
        let walls = zip(lattice.groups, isWall).filter(\.1).map(\.0.rect)
        let wallBits = isWall.enumerated()
            .reduce(UInt64(0)) { $1.element && $1.offset < 64 ? $0 | 1 << UInt64($1.offset) : $0 }
        let starts = ports(s, t, edge.sourcePort, edge.sourcePortCandidates, lattice, walls, scene)
        let ends = ports(t, s, edge.targetPort, edge.targetPortCandidates, lattice, walls, scene)
        guard !starts.isEmpty, !ends.isEmpty else { return nil }
        guard let found = search(starts, ends, lattice, walls, wallBits, relaxed: relaxed) else { return nil }
        for (cell, axis) in found.cells where congestionPenalty > 0 {
            if let index = lattice.indexed?.index(cell) {
                // `index` was only produced because `lattice.indexed` is non-nil.
                if axis == 1 {
                    lattice.indexed!.usage[index].horizontal += 1
                } else {
                    lattice.indexed!.usage[index].vertical += 1
                }
            } else if axis == 1 {
                lattice.usage[cell, default: Usage()].horizontal += 1
            } else {
                lattice.usage[cell, default: Usage()].vertical += 1
            }
        }
        return assemble(found.cells.map { lattice.centre($0.0) }, found.start, found.end)
    }

    /// Per side, the boundary point level with the other node on a cell-centre line (so the stub needs no jog), plus
    /// neighbouring lines so edges sharing a side can spread out instead of stacking on one point.
    private func ports(
        _ node: LayoutNode,
        _ other: LayoutNode,
        _ active: PortConstraint,
        _ candidates: [PortConstraint],
        _ lattice: Lattice,
        _ walls: [GridRect],
        _ scene: Scene
    ) -> [Port] {
        let sides = OrthogonalPorts.ranked(
            node,
            other: other,
            active: active,
            candidates: candidates,
            vertical: scene.vertical
        )
        let r = node.bounds
        let g = Float(lattice.grid)
        let cover = lattice.cover(r)
        var result: [Port] = []
        for (rank, side) in sides.enumerated() {
            let vertical = OrthogonalPorts.isVertical(side)
            let raw = OrthogonalPorts.point(node, side: side, toward: other.bounds)
            let lo = vertical ? r.left : r.top
            let hi = vertical ? r.right : r.bottom
            let inset = min(10, (hi - lo) / 4)
            let o = vertical ? lattice.origin.x : lattice.origin.y
            let value = vertical ? raw.x : raw.y
            let e = Lattice.tolerance / g
            let kmin = Int(ceil((lo + inset - o) / g - 0.5 - e))
            let kmax = Int(floor((hi - inset - o) / g - 0.5 + e))
            // Ties between two lines resolve a pixel away from the boundary, so they cannot flip on rounding noise.
            let preferred = min(max(Int(floor((value - o) / g + 0.05)), kmin), kmax)
            // Every line is a candidate, nearest first: a blocked neighbourhood must not hide a free line further along
            // the side.
            let lines: [Int?] =
                kmin <= kmax ? (kmin...kmax).sorted { (abs($0 - preferred), $0) < (abs($1 - preferred), $1) } : [nil]
            var accepted = 0
            for k in lines {
                if accepted >= Self.portLines { break }
                var p = raw
                if let k {
                    let snapped = o + (Float(k) + 0.5) * g
                    if vertical { p.x = snapped } else { p.y = snapped }
                }
                var entry = lattice.cell(p)
                switch side {
                case .top: entry.y = cover.minY - 1
                case .bottom: entry.y = cover.maxY + 1
                case .left: entry.x = cover.minX - 1
                default: entry.x = cover.maxX + 1
                }
                if lattice.isBlocked(entry) || walls.contains(where: { $0.contains(entry) }) { continue }
                let centre = lattice.centre(entry)
                let tip = vertical ? Point(x: p.x, y: centre.y) : Point(x: centre.x, y: p.y)
                let hit = scene.leaves
                    .query(
                        Rect(x: min(p.x, tip.x), y: min(p.y, tip.y), width: abs(p.x - tip.x), height: abs(p.y - tip.y))
                            .inflated(by: 0.5)
                    )
                    .contains { $0 !== node && $0.bounds.intersectsLine(p, tip) }
                if hit || (other.isGroup && other.bounds.intersectsLine(p, tip)) { continue }
                // The leg along the stub runs through the entry cell whichever way the search reaches it.
                // Each crossing of a route already at this node costs a quarter bend, like a side rank: more drives
                // routes round the long way.
                // It is judged on the likely route: out along the stub, level with the other node, then in.
                let guess = [
                    p, tip, vertical ? Point(x: other.center.x, y: tip.y) : Point(x: tip.x, y: other.center.y),
                    other.center,
                ]
                let cost =
                    Float(rank * bendPenalty) / 4 + 0.25 * Float(abs((k ?? preferred) - preferred))
                    + congestion(lattice.usageAt(entry), vertical ? 2 : 1)
                    + Float(bendPenalty) / 4 * Float(Self.crossings(guess, attached[ObjectIdentifier(node)] ?? []))
                result.append(Port(point: p, entry: entry, axis: vertical ? 2 : 1, cost: cost))
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

    /// Running along an occupied cell costs the full penalty; crossing it, half.
    private func congestion(_ usage: Usage?, _ axis: Int) -> Float {
        guard congestionPenalty > 0, let u = usage else { return 0 }
        let along = axis == 1 ? u.horizontal : u.vertical
        let across = axis == 1 ? u.vertical : u.horizontal
        return Float(along * congestionPenalty + across * max(1, congestionPenalty / 2))
    }

    private func search(
        _ starts: [Port],
        _ ends: [Port],
        _ lattice: Lattice,
        _ walls: [GridRect],
        _ wallBits: UInt64,
        relaxed: Bool
    ) -> (cells: [(Cell, Int)], start: Port, end: Port)? {
        if congestionPenalty == 0, let compressed = compressedSearch(starts, ends, lattice, walls) { return compressed }
        if let indexed = lattice.indexed {
            return indexedSearch(starts, ends, lattice, indexed, walls, wallBits, relaxed: relaxed)
        }
        return compressedSearch(starts, ends, lattice, walls)
    }

    /// Large sparse scenes use the same lattice, retaining port lines and both sides of every obstacle boundary.
    /// Adjacent retained lines form unobstructed jumps, so empty area does not consume a unit-cell search budget.
    /// Jump costs still charge every traversed cell. Zero-congestion routes retain jump endpoints; positive-congestion
    /// routes restore at most one million cells for usage accounting, otherwise taking the reported fallback.
    private func compressedSearch(
        _ starts: [Port],
        _ ends: [Port],
        _ lattice: Lattice,
        _ walls: [GridRect]
    ) -> (cells: [(Cell, Int)], start: Port, end: Port)? {
        let obstacles = lattice.rectangles + walls
        var xs = Set(starts.map(\.entry.x) + ends.map(\.entry.x))
        var ys = Set(starts.map(\.entry.y) + ends.map(\.entry.y))
        for r in obstacles {
            xs.formUnion([r.minX - 1, r.minX, r.maxX, r.maxX + 1])
            ys.formUnion([r.minY - 1, r.minY, r.maxY, r.maxY + 1])
        }
        xs.formUnion([lattice.extent.minX - 20, lattice.extent.maxX + 20])
        ys.formUnion([lattice.extent.minY - 20, lattice.extent.maxY + 20])
        let x = xs.sorted()
        let y = ys.sorted()
        let width = x.count
        // Oversized topologies are reported through the ordinary fallback instead of allocating unbounded memory.
        guard width <= 1_000_000 / max(1, y.count) else { return nil }
        let xi = Dictionary(uniqueKeysWithValues: x.enumerated().map { ($0.element, $0.offset) })
        let yi = Dictionary(uniqueKeysWithValues: y.enumerated().map { ($0.element, $0.offset) })
        var blocked = Array(repeating: false, count: width * y.count)
        for r in obstacles {
            for row in yi[required: r.minY]...yi[required: r.maxY] {
                for column in xi[required: r.minX]...xi[required: r.maxX] { blocked[row * width + column] = true }
            }
        }
        func vertex(_ c: Cell) -> Int { yi[required: c.y] * width + xi[required: c.x] }
        func cell(_ i: Int) -> Cell { Cell(x: x[i % width], y: y[i / width]) }
        var goals: [Int: Port] = [:]
        var sources: [Int: Port] = [:]
        for e in ends {
            let i = vertex(e.entry)
            if goals[i].map({ e.cost < $0.cost }) ?? true { goals[i] = e }
        }
        for s in starts { sources[vertex(s.entry) * 3 + s.axis - 1] = s }
        var heuristicCache = Array(repeating: Float(-1), count: blocked.count)
        func heuristic(_ i: Int) -> Float {
            if heuristicCache[i] >= 0 { return heuristicCache[i] }
            let c = cell(i)
            var value = Float.infinity
            for end in ends { value = min(value, Float(abs(end.entry.x - c.x) + abs(end.entry.y - c.y)) + end.cost) }
            heuristicCache[i] = value
            return value
        }
        var costs = Array(repeating: Float.infinity, count: blocked.count * 3)
        var previous = Array(repeating: -1, count: blocked.count * 3)
        var closed = Array(repeating: false, count: blocked.count * 3)
        var queue = RoutingPriorityQueue<Int>()
        for port in starts {
            let state = vertex(port.entry) * 3 + port.axis - 1
            if sources[required: state].cost == port.cost && port.cost < costs[state] {
                costs[state] = port.cost
                queue.push(state, priority: port.cost + heuristic(state / 3))
            }
        }
        var finish: Int?
        while let current = queue.pop() {
            if RoutingCompute.isCancelled { return nil }
            if closed[current] { continue }
            closed[current] = true
            let index = current / 3
            let axis = current % 3 + 1
            if axis == 3 {
                finish = current
                break
            }
            let row = index / width
            let column = index % width
            let from = cell(index)
            if let goal = goals[index] {
                let done = index * 3 + 2
                let cost = costs[current] + goal.cost + Float(axis != goal.axis ? bendPenalty : 0)
                if cost < costs[done] {
                    costs[done] = cost
                    previous[done] = current
                    queue.push(done, priority: cost)
                }
            }
            for (dx, dy, direction) in [(0, 1, 2), (0, -1, 2), (1, 0, 1), (-1, 0, 1)] {
                let cx = column + dx
                let cy = row + dy
                guard cx >= 0, cx < width, cy >= 0, cy < y.count else { continue }
                let i = cy * width + cx
                let next = i * 3 + direction - 1
                if blocked[i] || closed[next] { continue }
                let to = cell(i)
                let length = abs(to.x - from.x) + abs(to.y - from.y)
                // Positive congestion requires materialized per-cell usage. Reject oversized jumps before either
                // scanning their usage or expanding them; callers receive the normal explicit fallback diagnostic.
                if congestionPenalty > 0 && length > 1_000_000 { continue }
                var cost = costs[current] + Float(length) + Float(axis != direction ? bendPenalty : 0)
                if congestionPenalty > 0 && !lattice.usage.isEmpty {
                    for step in 1...length {
                        cost += congestion(lattice.usage[Cell(x: from.x + dx * step, y: from.y + dy * step)], direction)
                    }
                }
                if cost < costs[next] {
                    costs[next] = cost
                    previous[next] = current
                    queue.push(next, priority: cost + heuristic(i))
                }
            }
        }
        guard let finish else { return nil }
        var current = previous[finish]
        var states: [Int] = []
        let goal = goals[required: current / 3]
        while current >= 0 {
            states.append(current)
            let p = previous[current]
            if p < 0 { break }
            current = p
        }
        states.reverse()
        // With no congestion field, only jump endpoints are needed by assembly: expanding an enormous empty
        // span back into unit cells would defeat coordinate compression and can exhaust memory.
        if congestionPenalty == 0 {
            return (states.map { (cell($0 / 3), $0 % 3 + 1) }, sources[required: current], goal)
        }
        var cells: [(Cell, Int)] = [(cell(states[0] / 3), states[0] % 3 + 1)]
        for state in states.dropFirst() {
            // `cells` starts with the first state and only grows.
            let from = cells.last!.0
            let to = cell(state / 3)
            let axis = state % 3 + 1
            let dx = to.x == from.x ? 0 : (to.x > from.x ? 1 : -1)
            let dy = to.y == from.y ? 0 : (to.y > from.y ? 1 : -1)
            let length = abs(to.x - from.x) + abs(to.y - from.y)
            guard length <= 1_000_000 - cells.count else { return nil }
            for step in 1...length { cells.append((Cell(x: from.x + dx * step, y: from.y + dy * step), axis)) }
        }
        return (cells, sources[required: current], goal)
    }

    private func indexedSearch(
        _ starts: [Port],
        _ ends: [Port],
        _ lattice: Lattice,
        _ indexed: IndexedCells,
        _ walls: [GridRect],
        _ wallBits: UInt64,
        relaxed: Bool
    ) -> (cells: [(Cell, Int)], start: Port, end: Port)? {
        let storage = indexed.search
        storage.generation &+= 1
        if storage.generation == 0 {
            storage.seen = Array(repeating: 0, count: storage.seen.count)
            storage.closed = storage.seen
            storage.goalStamp = Array(repeating: 0, count: storage.goalStamp.count)
            storage.generation = 1
        }
        let generation = storage.generation
        // Walls come from `groupBits` when every group has a bit; otherwise each wall rect is tested.
        let groupBits = indexed.groupBits
        let scansWalls = groupBits == nil && !walls.isEmpty
        return storage.seen.withUnsafeMutableBufferPointer { seen in
            storage.closed.withUnsafeMutableBufferPointer { closed in
                storage.costs.withUnsafeMutableBufferPointer { costs in
                    storage.previous.withUnsafeMutableBufferPointer { previous in
                        storage.goalStamp.withUnsafeMutableBufferPointer { goalStamp in
                            storage.goal.withUnsafeMutableBufferPointer { goal in
                                // The cheapest end port per cell (the first on ties), found by a stamp instead of a
                                // hash.
                                func goalAt(_ i: Int) -> Port? { goalStamp[i] == generation ? ends[Int(goal[i])] : nil }
                                for (k, e) in ends.enumerated() {
                                    if let i = indexed.index(e.entry), goalAt(i).map({ e.cost < $0.cost }) ?? true {
                                        goalStamp[i] = generation
                                        goal[i] = Int32(k)
                                    }
                                }
                                var sources: [Int: Port] = [:]
                                for s in starts {
                                    if let i = indexed.index(s.entry) { sources[i * 3 + s.axis - 1] = s }
                                }
                                let entries = starts.map(\.entry) + ends.map(\.entry)
                                let slack = relaxed ? 20 : 4
                                // `route` only searches after checking that `starts` and `ends` are non-empty.
                                let low = Cell(
                                    x: min(lattice.extent.minX, entries.map(\.x).min()!) - slack,
                                    y: min(lattice.extent.minY, entries.map(\.y).min()!) - slack
                                )
                                let high = Cell(
                                    x: max(lattice.extent.maxX, entries.map(\.x).max()!) + slack,
                                    y: max(lattice.extent.maxY, entries.map(\.y).max()!) + slack
                                )
                                let goalLow = Cell(x: ends.map(\.entry.x).min()!, y: ends.map(\.entry.y).min()!)
                                let goalHigh = Cell(x: ends.map(\.entry.x).max()!, y: ends.map(\.entry.y).max()!)
                                func heuristic(_ c: Cell) -> Float {
                                    Float(
                                        max(goalLow.x - c.x, 0, c.x - goalHigh.x)
                                            + max(goalLow.y - c.y, 0, c.y - goalHigh.y)
                                    )
                                }
                                func isWall(_ i: Int, _ c: Cell) -> Bool {
                                    if let groupBits { return groupBits[i] & wallBits != 0 }
                                    return scansWalls && walls.contains { $0.contains(c) }
                                }
                                var queue = RoutingPriorityQueue<Int>()
                                for port in starts {
                                    guard let i = indexed.index(port.entry) else { continue }
                                    let state = i * 3 + port.axis - 1
                                    if sources[required: state].cost == port.cost
                                        && (seen[state] != generation || port.cost < costs[state])
                                    {
                                        seen[state] = generation
                                        costs[state] = port.cost
                                        previous[state] = -1
                                        queue.push(state, priority: port.cost + heuristic(port.entry))
                                    }
                                }
                                var finish: Int?
                                var pops = 0
                                let offsets = [(0, 1, 2), (0, -1, 2), (1, 0, 1), (-1, 0, 1)]
                                while let current = queue.pop() {
                                    // Reading the task-local cancellation state costs more than a pop; check it in
                                    // batches.
                                    pops &+= 1
                                    if pops & 255 == 0 && RoutingCompute.isCancelled { return nil }
                                    if closed[current] == generation { continue }
                                    closed[current] = generation
                                    let index = current / 3
                                    let direction = current % 3 + 1
                                    if direction == 3 {
                                        finish = current
                                        break
                                    }
                                    let cell = indexed.cell(index)
                                    let currentCost = costs[current]
                                    if let goal = goalAt(index) {
                                        let done = index * 3 + 2
                                        let cost =
                                            currentCost + goal.cost + Float(direction != goal.axis ? bendPenalty : 0)
                                        if seen[done] != generation || cost < costs[done] {
                                            seen[done] = generation
                                            costs[done] = cost
                                            previous[done] = current
                                            queue.push(done, priority: cost)
                                        }
                                    }
                                    for (dx, dy, axis) in offsets {
                                        let c = Cell(x: cell.x + dx, y: cell.y + dy)
                                        guard c.x >= low.x, c.x <= high.x, c.y >= low.y, c.y <= high.y,
                                            let i = indexed.index(c), !indexed.blocked[i], !isWall(i, c)
                                        else { continue }
                                        let next = i * 3 + axis - 1
                                        if closed[next] == generation { continue }
                                        let cost =
                                            currentCost + 1 + Float(direction != axis ? bendPenalty : 0)
                                            + congestion(indexed.usage[i], axis)
                                        if seen[next] != generation || cost < costs[next] {
                                            seen[next] = generation
                                            costs[next] = cost
                                            previous[next] = current
                                            queue.push(next, priority: cost + heuristic(c))
                                        }
                                    }
                                }
                                guard let finish else { return nil }
                                var current = previous[finish]
                                // `finish` is only pushed from a cell where `goalAt` was non-nil, and its
                                // predecessor is that same cell.
                                let goal = goalAt(current / 3)!
                                var cells: [(Cell, Int)] = []
                                while current >= 0 {
                                    cells.append((indexed.cell(current / 3), current % 3 + 1))
                                    let previous = previous[current]
                                    if previous < 0 { break }
                                    current = previous
                                }
                                cells.reverse()
                                return (cells, sources[required: current], goal)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Joins the boundary ports to the cell-centre chain, sliding each end run onto its port's line so no stair-step is
    /// needed.
    private func assemble(_ centres: [Point], _ start: Port, _ end: Port) -> [Point] {
        var pts = centres
        if pts.count == 1 { pts.append(pts[0]) }
        let n = pts.count
        let startVertical = start.axis == 2
        let endVertical = end.axis == 2
        func coordinate(_ p: Point, _ vertical: Bool) -> Float { vertical ? p.x : p.y }
        func set(_ p: inout Point, _ vertical: Bool, _ value: Float) {
            if vertical { p.x = value } else { p.y = value }
        }
        var ks = 0
        var ke = n - 1
        while ks + 1 < n && coordinate(pts[ks + 1], startVertical) == coordinate(pts[0], startVertical) { ks += 1 }
        while ke > 0 && coordinate(pts[ke - 1], endVertical) == coordinate(pts[n - 1], endVertical) { ke -= 1 }
        let sv = coordinate(start.point, startVertical)
        let ev = coordinate(end.point, endVertical)
        if startVertical == endVertical && ks >= ke {
            // One straight run between two parallel ports: step across once, midway.
            let m = (n - 1) / 2
            var result = Array(pts[...m])
            for i in result.indices { set(&result[i], startVertical, sv) }
            var jog = pts[m]
            set(&jog, startVertical, ev)
            result.append(jog)
            for i in (m + 1)..<n {
                var p = pts[i]
                set(&p, startVertical, ev)
                result.append(p)
            }
            pts = result
        } else {
            for i in 0...ks { set(&pts[i], startVertical, sv) }
            for i in ke..<n { set(&pts[i], endVertical, ev) }
        }
        return simplify([start.point] + pts + [end.point])
    }

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
