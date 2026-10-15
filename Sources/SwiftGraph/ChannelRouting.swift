import Foundation

/// Fixed-pitch lattice routing with direction-aware costs. Edges leave and enter on a node side (chosen to face the
/// other endpoint unless constrained), start and end on the node boundary perpendicular to it, and never cross an
/// endpoint's interior or a group the edge does not belong to. Failed searches are retried, then drawn as an
/// obstacle-aware polyline or an orthogonal L/Z between side ports; every such edge is reported.
public final class ChannelEdgeRouter: EdgeRouter {
    public var gridSize = 20
    public var bendPenalty = 2
    public var congestionPenalty = 2
    /// Edges that the lattice search could not route; they fall back to a polyline, an L/Z or a straight line.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    /// Free lattice lines kept per node side.
    private static let portLines = 5
    /// Routes already drawn at each node, so later port lines can avoid crossing them.
    private var attached: [ObjectIdentifier: [[Point]]] = [:]

    private struct Cell: Hashable { var x: Int; var y: Int }
    private struct GridRect {
        var minX: Int; var minY: Int; var maxX: Int; var maxY: Int
        func contains(_ p: Cell) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
    }
    private struct Usage { var horizontal = 0, vertical = 0 }
    /// Reused indexed search storage: a generation stamp avoids clearing the whole scene for every edge.
    private final class SearchStorage {
        var generation: UInt32 = 0
        var seen: [UInt32], closed: [UInt32], costs: [Float], previous: [Int]
        init(count: Int) {
            seen = Array(repeating: 0, count: count); closed = seen
            costs = Array(repeating: 0, count: count); previous = Array(repeating: -1, count: count)
        }
    }
    private struct IndexedCells {
        var bounds: GridRect, width: Int, blocked: [Bool], usage: [Usage], search: SearchStorage
        func index(_ c: Cell) -> Int? {
            guard bounds.contains(c) else { return nil }
            return (c.y - bounds.minY) * width + c.x - bounds.minX
        }
        func cell(_ i: Int) -> Cell { Cell(x: bounds.minX + i % width, y: bounds.minY + i / width) }
    }
    /// A node side as a search endpoint: the boundary point, and the first free cell straight out from it.
    private struct Port { var point: Point; var entry: Cell; var axis: Int; var cost: Float }
    private struct Lattice {
        var grid: Int, origin: Point
        var groups: [(node: LayoutNode, rect: GridRect)] = [], usage: [Cell: Usage] = [:]
        var indexed: IndexedCells?
        var rectangles: [GridRect] = []
        func isBlocked(_ c: Cell) -> Bool {
            if let indexed, let i = indexed.index(c) { return indexed.blocked[i] }
            return rectangles.contains { $0.contains(c) }
        }
        func usageAt(_ c: Cell) -> Usage? { if let indexed, let i = indexed.index(c) { return indexed.usage[i] }; return usage[c] }
        /// Cells covered by any node: beyond it the lattice is empty, so the search only needs a few cells of slack.
        var extent = GridRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
        func cell(_ p: Point) -> Cell { Cell(x: Int(floor((p.x - origin.x) / Float(grid))), y: Int(floor((p.y - origin.y) / Float(grid)))) }
        func centre(_ c: Cell) -> Point { Point(x: origin.x + (Float(c.x) + 0.5) * Float(grid), y: origin.y + (Float(c.y) + 0.5) * Float(grid)) }
        /// Cells a rectangle overlaps; touching a cell boundary (to within `tolerance`) does not occupy the next cell.
        func cover(_ r: Rect) -> GridRect {
            let g = Float(grid), e = Self.tolerance / g, minX = Int(floor((r.left - origin.x) / g + e)), minY = Int(floor((r.top - origin.y) / g + e))
            return GridRect(minX: minX, minY: minY, maxX: max(minX, Int(ceil((r.right - origin.x) / g - e)) - 1), maxY: max(minY, Int(ceil((r.bottom - origin.y) / g - e)) - 1))
        }
        /// Geometry differing by less than this (as GPU layouts do) must not change which cells a node occupies.
        static let tolerance: Float = 0.05
    }
    private struct Scene { var graph: LayoutGraph; var leaves: QuadTree<LayoutNode>; var vertical: Bool }

    public func routeEdges(_ graph: LayoutGraph) {
        unroutableEdges = []; attached = [:]
        guard !graph.nodes.isEmpty else { return }
        precondition(gridSize > 0, "gridSize must be positive")
        let leaves = QuadTree<LayoutNode>(bounds: enclosingBounds(graph.nodes).inflated(by: 100))
        for n in graph.nodes where !n.isGroup { leaves.insert(bounds: n.bounds, item: n) }
        for group in graph.nodes where group.isGroup {
            if let r = group.groupHeaderBounds, r.width > 0 && r.height > 0 {
                let header = LayoutNode(id: "header:" + group.id, width: r.width, height: r.height)
                header.bounds = r; leaves.insert(bounds: r, item: header)
            }
        }
        let scene = Scene(graph: graph, leaves: leaves, vertical: OrthogonalPorts.flow(graph).vertical)
        var lattice = makeLattice(graph, grid: gridSize), fine: Lattice?
        for edge in graph.edges where edge.source !== edge.target {
            if RoutingCompute.isCancelled { return }
            var path = route(edge, &lattice, scene, relaxed: false) ?? route(edge, &lattice, scene, relaxed: true)
            if path == nil && gridSize >= 4 {
                if fine == nil { fine = makeLattice(graph, grid: gridSize / 2) }
                path = route(edge, &fine!, scene, relaxed: true)
            }
            if RoutingCompute.isCancelled { return }
            if path == nil { path = RoutingFallback.route(edge, graph); unroutableEdges.append(edge) }
            edge.path = path!
            for node in [edge.source, edge.target] { attached[ObjectIdentifier(node), default: []].append(edge.path) }
        }
    }
    private func makeLattice(_ graph: LayoutGraph, grid: Int) -> Lattice {
        var lattice = Lattice(grid: grid, origin: Point(x: graph.nodes.map(\.x).min()! - 50, y: graph.nodes.map(\.y).min()! - 50))
        let headers = graph.nodes.filter(\.isGroup).compactMap(\.groupHeaderBounds).filter { $0.width > 0 && $0.height > 0 }
        let rectangles = (graph.nodes.filter { !$0.isGroup }.map(\.bounds) + headers).map { lattice.cover($0) }
        lattice.rectangles = rectangles
        let covers = graph.nodes.map { lattice.cover($0.bounds) }
        lattice.extent = GridRect(minX: covers.map(\.minX).min()!, minY: covers.map(\.minY).min()!, maxX: covers.map(\.maxX).max()!, maxY: covers.map(\.maxY).max()!)
        lattice.groups = graph.nodes.filter { $0.isGroup && $0.width > 0 && $0.height > 0 }.map { ($0, lattice.cover($0.bounds)) }
        // The common case fits comfortably in indexed storage. Extremely sparse/large scenes retain the hash search.
        let r = lattice.extent, width = r.maxX - r.minX + 41, height = r.maxY - r.minY + 41
        if width > 0, height > 0, width <= 1_000_000 / height {
            let fits = rectangles.allSatisfy { r in [r.minX, r.minY, r.maxX, r.maxY].allSatisfy { Int32(exactly: $0) != nil } }
            let occupied = fits ? RoutingCompute.current?.occupiedCells(rectangles.map { SIMD4(Int32($0.minX), Int32($0.minY), Int32($0.maxX), Int32($0.maxY)) }) : nil
            let bounds = GridRect(minX: r.minX - 20, minY: r.minY - 20, maxX: r.maxX + 20, maxY: r.maxY + 20)
            var indexed = IndexedCells(bounds: bounds, width: width, blocked: Array(repeating: false, count: width * height), usage: Array(repeating: Usage(), count: width * height), search: SearchStorage(count: width * height * 3))
            if let occupied {
                for cell in occupied { indexed.blocked[indexed.index(Cell(x: Int(cell.x), y: Int(cell.y)))!] = true }
            } else {
                for rect in rectangles {
                    for y in rect.minY...rect.maxY { for x in rect.minX...rect.maxX { indexed.blocked[indexed.index(Cell(x: x, y: y))!] = true } }
                }
            }
            lattice.indexed = indexed
        }
        return lattice
    }
    private func route(_ edge: LayoutEdge, _ lattice: inout Lattice, _ scene: Scene, relaxed: Bool) -> [Point]? {
        let s = edge.source, t = edge.target
        if isAncestor(s, of: t) || isAncestor(t, of: s) { return nil }
        // Groups are walls except those the edge starts or ends inside; an endpoint group's interior is never passable.
        let walls = lattice.groups.filter { $0.node === s || $0.node === t || !(isAncestor($0.node, of: s) || isAncestor($0.node, of: t)) }.map(\.rect)
        let starts = ports(s, t, edge.sourcePort, edge.sourcePortCandidates, lattice, walls, scene)
        let ends = ports(t, s, edge.targetPort, edge.targetPortCandidates, lattice, walls, scene)
        guard !starts.isEmpty, !ends.isEmpty else { return nil }
        guard let found = search(starts, ends, lattice, walls, relaxed: relaxed) else { return nil }
        for (cell, axis) in found.cells where congestionPenalty > 0 {
            if let index = lattice.indexed?.index(cell) {
                if axis == 1 { lattice.indexed!.usage[index].horizontal += 1 } else { lattice.indexed!.usage[index].vertical += 1 }
            } else if axis == 1 { lattice.usage[cell, default: Usage()].horizontal += 1 } else { lattice.usage[cell, default: Usage()].vertical += 1 }
        }
        return assemble(found.cells.map { lattice.centre($0.0) }, found.start, found.end)
    }
    /// Per side, the boundary point level with the other node on a cell-centre line (so the stub needs no jog), plus
    /// neighbouring lines so edges sharing a side can spread out instead of stacking on one point.
    private func ports(_ node: LayoutNode, _ other: LayoutNode, _ active: PortConstraint, _ candidates: [PortConstraint], _ lattice: Lattice, _ walls: [GridRect], _ scene: Scene) -> [Port] {
        let sides = OrthogonalPorts.ranked(node, other: other, active: active, candidates: candidates, vertical: scene.vertical)
        let r = node.bounds, g = Float(lattice.grid), cover = lattice.cover(r)
        var result: [Port] = []
        for (rank, side) in sides.enumerated() {
            let vertical = OrthogonalPorts.isVertical(side), raw = OrthogonalPorts.point(node, side: side, toward: other.bounds)
            let lo = vertical ? r.left : r.top, hi = vertical ? r.right : r.bottom, inset = min(10, (hi - lo) / 4)
            let o = vertical ? lattice.origin.x : lattice.origin.y, value = vertical ? raw.x : raw.y
            let e = Lattice.tolerance / g, kmin = Int(ceil((lo + inset - o) / g - 0.5 - e)), kmax = Int(floor((hi - inset - o) / g - 0.5 + e))
            // Ties between two lines resolve a pixel away from the boundary, so they cannot flip on rounding noise.
            let preferred = min(max(Int(floor((value - o) / g + 0.05)), kmin), kmax)
            // Every line is a candidate, nearest first: a blocked neighbourhood must not hide a free line further along the side.
            let lines: [Int?] = kmin <= kmax ? (kmin...kmax).sorted { (abs($0 - preferred), $0) < (abs($1 - preferred), $1) } : [nil]
            var accepted = 0
            for k in lines {
                if accepted >= Self.portLines { break }
                var p = raw
                if let k { let snapped = o + (Float(k) + 0.5) * g; if vertical { p.x = snapped } else { p.y = snapped } }
                var entry = lattice.cell(p)
                switch side {
                case .top: entry.y = cover.minY - 1
                case .bottom: entry.y = cover.maxY + 1
                case .left: entry.x = cover.minX - 1
                default: entry.x = cover.maxX + 1
                }
                if lattice.isBlocked(entry) || walls.contains(where: { $0.contains(entry) }) { continue }
                let centre = lattice.centre(entry), tip = vertical ? Point(x: p.x, y: centre.y) : Point(x: centre.x, y: p.y)
                let hit = scene.leaves.query(Rect(x: min(p.x, tip.x), y: min(p.y, tip.y), width: abs(p.x - tip.x), height: abs(p.y - tip.y)).inflated(by: 0.5)).contains { $0 !== node && $0.bounds.intersectsLine(p, tip) }
                if hit || (other.isGroup && other.bounds.intersectsLine(p, tip)) { continue }
                // The leg along the stub runs through the entry cell whichever way the search reaches it.
                // Each crossing of a route already at this node costs a quarter bend, like a side rank: more drives routes round the long way.
                // It is judged on the likely route: out along the stub, level with the other node, then in.
                let guess = [p, tip, vertical ? Point(x: other.center.x, y: tip.y) : Point(x: tip.x, y: other.center.y), other.center]
                let cost = Float(rank * bendPenalty) / 4 + 0.25 * Float(abs((k ?? preferred) - preferred)) + congestion(lattice.usageAt(entry), vertical ? 2 : 1)
                    + Float(bendPenalty) / 4 * Float(Self.crossings(guess, attached[ObjectIdentifier(node)] ?? []))
                result.append(Port(point: p, entry: entry, axis: vertical ? 2 : 1, cost: cost)); accepted += 1
            }
        }
        return result
    }
    private static func crossings(_ path: [Point], _ routes: [[Point]]) -> Int {
        func cross(_ a: Point, _ b: Point) -> Float { a.x * b.y - a.y * b.x }
        var count = 0
        for (a, b) in zip(path, path.dropFirst()) { for route in routes { for (c, d) in zip(route, route.dropFirst()) {
            let u = b - a, v = d - c, denominator = cross(u, v)
            guard abs(denominator) > 1e-6 else { continue }
            let t = cross(c - a, v) / denominator, s = cross(c - a, u) / denominator
            if t > 1e-5 && t < 1 - 1e-5 && s > 1e-5 && s < 1 - 1e-5 { count += 1 }
        } } }
        return count
    }
    /// Running along an occupied cell costs the full penalty; crossing it, half.
    private func congestion(_ usage: Usage?, _ axis: Int) -> Float {
        guard congestionPenalty > 0, let u = usage else { return 0 }
        let along = axis == 1 ? u.horizontal : u.vertical, across = axis == 1 ? u.vertical : u.horizontal
        return Float(along * congestionPenalty + across * max(1, congestionPenalty / 2))
    }
    private func search(_ starts: [Port], _ ends: [Port], _ lattice: Lattice, _ walls: [GridRect], relaxed: Bool) -> (cells: [(Cell, Int)], start: Port, end: Port)? {
        if congestionPenalty == 0, let compressed = compressedSearch(starts, ends, lattice, walls) { return compressed }
        if let indexed = lattice.indexed { return indexedSearch(starts, ends, lattice, indexed, walls, relaxed: relaxed) }
        return compressedSearch(starts, ends, lattice, walls)
    }
    /// Large sparse scenes use the same lattice, retaining port lines and both sides of every obstacle boundary.
    /// Adjacent retained lines form unobstructed jumps, so empty area does not consume a unit-cell search budget.
    /// Jump costs still charge every traversed cell. Zero-congestion routes retain jump endpoints; positive-congestion
    /// routes restore at most one million cells for usage accounting, otherwise taking the reported fallback.
    private func compressedSearch(_ starts: [Port], _ ends: [Port], _ lattice: Lattice, _ walls: [GridRect]) -> (cells: [(Cell, Int)], start: Port, end: Port)? {
        let obstacles = lattice.rectangles + walls
        var xs = Set(starts.map(\.entry.x) + ends.map(\.entry.x)), ys = Set(starts.map(\.entry.y) + ends.map(\.entry.y))
        for r in obstacles {
            xs.formUnion([r.minX - 1, r.minX, r.maxX, r.maxX + 1]); ys.formUnion([r.minY - 1, r.minY, r.maxY, r.maxY + 1])
        }
        xs.formUnion([lattice.extent.minX - 20, lattice.extent.maxX + 20]); ys.formUnion([lattice.extent.minY - 20, lattice.extent.maxY + 20])
        let x = xs.sorted(), y = ys.sorted(), width = x.count
        // Oversized topologies are reported through the ordinary fallback instead of allocating unbounded memory.
        guard width <= 1_000_000 / max(1, y.count) else { return nil }
        let xi = Dictionary(uniqueKeysWithValues: x.enumerated().map { ($0.element, $0.offset) }), yi = Dictionary(uniqueKeysWithValues: y.enumerated().map { ($0.element, $0.offset) })
        var blocked = Array(repeating: false, count: width * y.count)
        for r in obstacles {
            for row in yi[r.minY]!...yi[r.maxY]! { for column in xi[r.minX]!...xi[r.maxX]! { blocked[row * width + column] = true } }
        }
        func vertex(_ c: Cell) -> Int { yi[c.y]! * width + xi[c.x]! }
        func cell(_ i: Int) -> Cell { Cell(x: x[i % width], y: y[i / width]) }
        var goals: [Int: Port] = [:], sources: [Int: Port] = [:]
        for e in ends { let i = vertex(e.entry); if goals[i].map({ e.cost < $0.cost }) ?? true { goals[i] = e } }
        for s in starts { sources[vertex(s.entry) * 3 + s.axis - 1] = s }
        var heuristicCache = Array(repeating: Float(-1), count: blocked.count)
        func heuristic(_ i: Int) -> Float {
            if heuristicCache[i] >= 0 { return heuristicCache[i] }
            let c = cell(i)
            var value = Float.infinity
            for end in ends { value = min(value, Float(abs(end.entry.x - c.x) + abs(end.entry.y - c.y)) + end.cost) }
            heuristicCache[i] = value; return value
        }
        var costs = Array(repeating: Float.infinity, count: blocked.count * 3), previous = Array(repeating: -1, count: blocked.count * 3), closed = Array(repeating: false, count: blocked.count * 3), queue = RoutingPriorityQueue<Int>()
        for port in starts {
            let state = vertex(port.entry) * 3 + port.axis - 1
            if sources[state]!.cost == port.cost && port.cost < costs[state] { costs[state] = port.cost; queue.push(state, priority: port.cost + heuristic(state / 3)) }
        }
        var finish: Int?
        while let current = queue.pop() {
            if RoutingCompute.isCancelled { return nil }
            if closed[current] { continue }; closed[current] = true
            let index = current / 3, axis = current % 3 + 1
            if axis == 3 { finish = current; break }
            let row = index / width, column = index % width, from = cell(index)
            if let goal = goals[index] {
                let done = index * 3 + 2, cost = costs[current] + goal.cost + Float(axis != goal.axis ? bendPenalty : 0)
                if cost < costs[done] { costs[done] = cost; previous[done] = current; queue.push(done, priority: cost) }
            }
            for (dx, dy, direction) in [(0, 1, 2), (0, -1, 2), (1, 0, 1), (-1, 0, 1)] {
                let cx = column + dx, cy = row + dy
                guard cx >= 0, cx < width, cy >= 0, cy < y.count else { continue }
                let i = cy * width + cx, next = i * 3 + direction - 1
                if blocked[i] || closed[next] { continue }
                let to = cell(i), length = abs(to.x - from.x) + abs(to.y - from.y)
                // Positive congestion requires materialized per-cell usage. Reject oversized jumps before either
                // scanning their usage or expanding them; callers receive the normal explicit fallback diagnostic.
                if congestionPenalty > 0 && length > 1_000_000 { continue }
                var cost = costs[current] + Float(length) + Float(axis != direction ? bendPenalty : 0)
                if congestionPenalty > 0 && !lattice.usage.isEmpty {
                    for step in 1...length { cost += congestion(lattice.usage[Cell(x: from.x + dx * step, y: from.y + dy * step)], direction) }
                }
                if cost < costs[next] { costs[next] = cost; previous[next] = current; queue.push(next, priority: cost + heuristic(i)) }
            }
        }
        guard let finish else { return nil }
        var current = previous[finish], states: [Int] = []
        let goal = goals[current / 3]!
        while current >= 0 { states.append(current); let p = previous[current]; if p < 0 { break }; current = p }
        states.reverse()
        // With no congestion field, only jump endpoints are needed by assembly: expanding an enormous empty
        // span back into unit cells would defeat coordinate compression and can exhaust memory.
        if congestionPenalty == 0 { return (states.map { (cell($0 / 3), $0 % 3 + 1) }, sources[current]!, goal) }
        var cells: [(Cell, Int)] = [(cell(states[0] / 3), states[0] % 3 + 1)]
        for state in states.dropFirst() {
            let from = cells.last!.0, to = cell(state / 3), axis = state % 3 + 1
            let dx = to.x == from.x ? 0 : (to.x > from.x ? 1 : -1), dy = to.y == from.y ? 0 : (to.y > from.y ? 1 : -1)
            let length = abs(to.x - from.x) + abs(to.y - from.y)
            guard length <= 1_000_000 - cells.count else { return nil }
            for step in 1...length { cells.append((Cell(x: from.x + dx * step, y: from.y + dy * step), axis)) }
        }
        return (cells, sources[current]!, goal)
    }

    private func indexedSearch(_ starts: [Port], _ ends: [Port], _ lattice: Lattice, _ indexed: IndexedCells, _ walls: [GridRect], relaxed: Bool) -> (cells: [(Cell, Int)], start: Port, end: Port)? {
        let storage = indexed.search
        storage.generation &+= 1
        if storage.generation == 0 { storage.seen = Array(repeating: 0, count: storage.seen.count); storage.closed = storage.seen; storage.generation = 1 }
        let generation = storage.generation
        return storage.seen.withUnsafeMutableBufferPointer { seen in
            storage.closed.withUnsafeMutableBufferPointer { closed in
                storage.costs.withUnsafeMutableBufferPointer { costs in
                    storage.previous.withUnsafeMutableBufferPointer { previous in
                        var goals: [Int: Port] = [:], sources: [Int: Port] = [:]
                        for e in ends { if let i = indexed.index(e.entry), goals[i].map({ e.cost < $0.cost }) ?? true { goals[i] = e } }
                        for s in starts { if let i = indexed.index(s.entry) { sources[i * 3 + s.axis - 1] = s } }
                        let entries = starts.map(\.entry) + ends.map(\.entry)
                        let slack = relaxed ? 20 : 4
                        let low = Cell(x: min(lattice.extent.minX, entries.map(\.x).min()!) - slack, y: min(lattice.extent.minY, entries.map(\.y).min()!) - slack)
                        let high = Cell(x: max(lattice.extent.maxX, entries.map(\.x).max()!) + slack, y: max(lattice.extent.maxY, entries.map(\.y).max()!) + slack)
                        let goalLow = Cell(x: ends.map(\.entry.x).min()!, y: ends.map(\.entry.y).min()!), goalHigh = Cell(x: ends.map(\.entry.x).max()!, y: ends.map(\.entry.y).max()!)
                        func heuristic(_ c: Cell) -> Float { Float(max(goalLow.x - c.x, 0, c.x - goalHigh.x) + max(goalLow.y - c.y, 0, c.y - goalHigh.y)) }
                        var queue = RoutingPriorityQueue<Int>()
                        for port in starts {
                            guard let i = indexed.index(port.entry) else { continue }
                            let state = i * 3 + port.axis - 1
                            if sources[state]!.cost == port.cost && (seen[state] != generation || port.cost < costs[state]) {
                                seen[state] = generation; costs[state] = port.cost; previous[state] = -1
                                queue.push(state, priority: port.cost + heuristic(port.entry))
                            }
                        }
                        var finish: Int?
                        let offsets = [(0, 1, 2), (0, -1, 2), (1, 0, 1), (-1, 0, 1)]
                        while let current = queue.pop() {
                            if RoutingCompute.isCancelled { return nil }
                            if closed[current] == generation { continue }; closed[current] = generation
                            let index = current / 3, direction = current % 3 + 1
                            if direction == 3 { finish = current; break }
                            let cell = indexed.cell(index), currentCost = costs[current]
                            if let goal = goals[index] {
                                let done = index * 3 + 2, cost = currentCost + goal.cost + Float(direction != goal.axis ? bendPenalty : 0)
                                if seen[done] != generation || cost < costs[done] {
                                    seen[done] = generation; costs[done] = cost; previous[done] = current; queue.push(done, priority: cost)
                                }
                            }
                            for (dx, dy, axis) in offsets {
                                let c = Cell(x: cell.x + dx, y: cell.y + dy)
                                guard c.x >= low.x, c.x <= high.x, c.y >= low.y, c.y <= high.y, let i = indexed.index(c), !indexed.blocked[i], !walls.contains(where: { $0.contains(c) }) else { continue }
                                let next = i * 3 + axis - 1
                                if closed[next] == generation { continue }
                                let cost = currentCost + 1 + Float(direction != axis ? bendPenalty : 0) + congestion(indexed.usage[i], axis)
                                if seen[next] != generation || cost < costs[next] {
                                    seen[next] = generation; costs[next] = cost; previous[next] = current
                                    queue.push(next, priority: cost + heuristic(c))
                                }
                            }
                        }
                        guard let finish else { return nil }
                        var current = previous[finish]
                        let goal = goals[current / 3]!
                        var cells: [(Cell, Int)] = []
                        while current >= 0 { cells.append((indexed.cell(current / 3), current % 3 + 1)); let previous = previous[current]; if previous < 0 { break }; current = previous }
                        cells.reverse()
                        return (cells, sources[current]!, goal)
                    }
                }
            }
        }
    }

    /// Joins the boundary ports to the cell-centre chain, sliding each end run onto its port's line so no stair-step is needed.
    private func assemble(_ centres: [Point], _ start: Port, _ end: Port) -> [Point] {
        var pts = centres
        if pts.count == 1 { pts.append(pts[0]) }
        let n = pts.count, startVertical = start.axis == 2, endVertical = end.axis == 2
        func coordinate(_ p: Point, _ vertical: Bool) -> Float { vertical ? p.x : p.y }
        func set(_ p: inout Point, _ vertical: Bool, _ value: Float) { if vertical { p.x = value } else { p.y = value } }
        var ks = 0, ke = n - 1
        while ks + 1 < n && coordinate(pts[ks + 1], startVertical) == coordinate(pts[0], startVertical) { ks += 1 }
        while ke > 0 && coordinate(pts[ke - 1], endVertical) == coordinate(pts[n - 1], endVertical) { ke -= 1 }
        let sv = coordinate(start.point, startVertical), ev = coordinate(end.point, endVertical)
        if startVertical == endVertical && ks >= ke {
            // One straight run between two parallel ports: step across once, midway.
            let m = (n - 1) / 2
            var result = Array(pts[...m]); for i in result.indices { set(&result[i], startVertical, sv) }
            var jog = pts[m]; set(&jog, startVertical, ev); result.append(jog)
            for i in (m + 1)..<n { var p = pts[i]; set(&p, startVertical, ev); result.append(p) }
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
                let a = path[i] - path[i - 1], b = path[i + 1] - path[i]
                if abs(a.x * b.y - a.y * b.x) <= 0.001 { path.remove(at: i) }
            }
        }
        return path
    }
}

/// Side choice and boundary ports shared by the orthogonal routers.
enum OrthogonalPorts {
    static func isVertical(_ side: PortConstraint) -> Bool { side == .top || side == .bottom }
    static func opposite(_ side: PortConstraint) -> PortConstraint {
        switch side { case .top: .bottom; case .bottom: .top; case .left: .right; case .right: .left; case .none: .none }
    }
    /// Dominant direction of travel along the edges, by centre displacement; `direction` is nil unless most of it points one way.
    static func flow(_ graph: LayoutGraph) -> (vertical: Bool, direction: Point?) {
        var sx: Float = 0, sy: Float = 0, ax: Float = 0, ay: Float = 0
        for e in graph.edges where e.source !== e.target {
            let d = e.target.center - e.source.center; sx += d.x; sy += d.y; ax += abs(d.x); ay += abs(d.y)
        }
        let vertical = ay >= ax
        if vertical { return (true, ay > 0 && abs(sy) >= ay / 2 ? Point(x: 0, y: sy > 0 ? 1 : -1) : nil) }
        return (false, ax > 0 && abs(sx) >= ax / 2 ? Point(x: sx > 0 ? 1 : -1, y: 0) : nil)
    }
    /// The sides an edge to `other` may use, facing sides first; a tie between the two axes follows the layout flow.
    static func ranked(_ node: LayoutNode, other: LayoutNode, active: PortConstraint, candidates: [PortConstraint], vertical flowVertical: Bool) -> [PortConstraint] {
        if active != .none { return [active] }
        let r = node.bounds, o = other.bounds
        let gapX = max(o.left - r.right, r.left - o.right), gapY = max(o.top - r.bottom, r.top - o.bottom)
        // Ties are decided with a half-unit tolerance so GPU-rounded layouts choose the same sides.
        let horizontal = abs(gapX - gapY) > 0.5 ? gapX > gapY : !flowVertical
        let h: PortConstraint = o.center.x < r.center.x - 0.5 ? .left : .right, v: PortConstraint = o.center.y < r.center.y - 0.5 ? .top : .bottom
        let sides = horizontal ? [h, v, opposite(v), opposite(h)] : [v, h, opposite(h), opposite(v)]
        let allowed = candidates.filter { $0 != .none }
        return allowed.isEmpty ? sides : sides.filter(allowed.contains)
    }
    /// The side's point on the node boundary, level with the other node where they overlap, kept off the corners.
    static func point(_ node: LayoutNode, side: PortConstraint, toward other: Rect) -> Point {
        let r = node.bounds, vertical = isVertical(side)
        let lo = vertical ? r.left : r.top, hi = vertical ? r.right : r.bottom, inset = min(10, (hi - lo) / 4)
        let otherLo = vertical ? other.left : other.top, otherHi = vertical ? other.right : other.bottom
        let value = max(lo, otherLo) < min(hi, otherHi) ? (max(lo, otherLo) + min(hi, otherHi)) / 2 : (otherLo + otherHi) / 2
        let along = min(max(value, lo + inset), hi - inset)
        switch side {
        case .top: return Point(x: along, y: r.top)
        case .bottom: return Point(x: along, y: r.bottom)
        case .left: return Point(x: r.left, y: along)
        default: return Point(x: r.right, y: along)
        }
    }
}

/// Last resorts for orthogonal routers when their own search fails: an orthogonal L/Z between side ports if one is
/// clear, otherwise an obstacle-aware polyline between those ports, then the least bad L/Z, and only then a straight line.
enum RoutingFallback {
    static func route(_ edge: LayoutEdge, _ graph: LayoutGraph, padding: Float = 10) -> [Point] {
        let flow = OrthogonalPorts.flow(graph).vertical
        let from = OrthogonalPorts.ranked(edge.source, other: edge.target, active: edge.sourcePort, candidates: edge.sourcePortCandidates, vertical: flow).prefix(2)
        let to = OrthogonalPorts.ranked(edge.target, other: edge.source, active: edge.targetPort, candidates: edge.targetPortCandidates, vertical: flow).prefix(2)
        let obstacles = ObstaclePolyline.obstacles(edge, graph)
        let ends = [edge.source.bounds, edge.target.bounds].filter { $0.width > 0 && $0.height > 0 }.map { $0.inflated(by: -1e-5) }
        var lz: [[Point]] = [], combos: [(Point, Point, Point, Point)] = []
        for a in from { for b in to {
            let ps = OrthogonalPorts.point(edge.source, side: a, toward: edge.target.bounds), pt = OrthogonalPorts.point(edge.target, side: b, toward: edge.source.bounds)
            combos.append((ps, portDirection(a), pt, portDirection(b)))
            if let path = orthogonal(ps, portDirection(a), pt, portDirection(b)) { lz.append(path) }
        } }
        func clear(_ path: [Point]) -> Bool {
            ObstaclePolyline.clear(path, obstacles) && !zip(path, path.dropFirst()).contains { a, b in ends.contains { $0.intersectsLine(a, b) } }
        }
        if let path = lz.first(where: clear) { return path }
        for (ps, ds, pt, dt) in combos {
            // Search from just outside each port, so the route leaves and arrives perpendicular to its side.
            let a = ps + ds * padding, b = pt + dt * padding
            if let found = ObstaclePolyline.search(a, b, obstacles + [edge.source.bounds, edge.target.bounds], padding: padding), found.count >= 2 {
                let path = compactPath([ps] + found + [pt]); if clear(path) { return path }
            }
        }
        if let path = lz.min(by: { hits($0, obstacles) < hits($1, obstacles) }) { return path }
        return [edge.source.center, edge.target.center]
    }
    private static func hits(_ path: [Point], _ obstacles: [Rect]) -> Int { zip(path, path.dropFirst()).reduce(0) { n, s in n + obstacles.filter { $0.intersectsLine(s.0, s.1) }.count } }
    /// L between perpendicular ports, Z between facing ones, U between ports on the same side; nil if the ports face away.
    private static func orthogonal(_ ps: Point, _ ds: Point, _ pt: Point, _ dt: Point) -> [Point]? {
        let sv = ds.x == 0, tv = dt.x == 0
        if sv != tv {
            let corner = sv ? Point(x: ps.x, y: pt.y) : Point(x: pt.x, y: ps.y)
            return (corner - ps).x * ds.x + (corner - ps).y * ds.y > 1e-5 && (corner - pt).x * dt.x + (corner - pt).y * dt.y > 1e-5 ? compactPath([ps, corner, pt]) : nil
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

/// Quaternary min-heap with priority-only tie handling, like System.Collections.Generic.PriorityQueue.
/// Router tie handling matters: equally short paths become inputs to later congestion/bundling passes.
struct RoutingPriorityQueue<Value> {
    private var items: [(Value, Float)] = []
    mutating func push(_ value: Value, priority: Float) {
        var i = items.count; items.append((value, priority))
        while i > 0 {
            let p = (i - 1) / 4
            if priority >= items[p].1 { break }
            items[i] = items[p]; i = p
        }
        items[i] = (value, priority)
    }
    mutating func pop() -> Value? {
        guard !items.isEmpty else { return nil }
        let result = items[0].0, last = items.removeLast()
        guard !items.isEmpty else { return result }
        var i = 0
        while i * 4 + 1 < items.count {
            let first = i * 4 + 1
            var best = first
            for j in (first + 1)..<min(first + 4, items.count) where items[j].1 < items[best].1 { best = j }
            if last.1 <= items[best].1 { break }
            items[i] = items[best]; i = best
        }
        items[i] = last; return result
    }
}
