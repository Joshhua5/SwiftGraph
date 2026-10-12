import Foundation

/// Fixed-pitch lattice routing, matching Waring's cell occupancy and direction-aware costs.
public final class ChannelEdgeRouter: EdgeRouter {
    public var gridSize = 20
    public var bendPenalty = 2
    public var congestionPenalty = 2
    /// Edges for which search fell back to a direct port-to-port line.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}

    private struct Cell: Hashable { var x: Int; var y: Int }
    private struct State: Hashable { var cell: Cell; var direction: Int }
    private struct GridRect {
        var minX: Int; var minY: Int; var maxX: Int; var maxY: Int
        func contains(_ p: Cell) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
    }
    public func routeEdges(_ graph: LayoutGraph) {
        unroutableEdges = []
        guard !graph.nodes.isEmpty else { return }
        precondition(gridSize > 0, "gridSize must be positive")
        let origin = Point(x: graph.nodes.map(\.x).min()! - 50, y: graph.nodes.map(\.y).min()! - 50)
        func cell(_ p: Point) -> Cell { Cell(x: Int((p.x - origin.x) / Double(gridSize)), y: Int((p.y - origin.y) / Double(gridSize))) }
        func rect(_ r: Rect) -> GridRect {
            let a = cell(Point(x: r.left, y: r.top)), b = cell(Point(x: r.right, y: r.bottom))
            return GridRect(minX: a.x, minY: a.y, maxX: b.x, maxY: b.y)
        }
        var blocked = Set<Cell>(), usage: [Cell: Int] = [:]
        let rectangles = graph.nodes.filter { !$0.isGroup }.map { rect($0.bounds) }
        let fits = rectangles.allSatisfy { r in [r.minX, r.minY, r.maxX, r.maxY].allSatisfy { Int32(exactly: $0) != nil } }
        let occupied = fits ? RoutingCompute.current?.occupiedCells(rectangles.map { SIMD4(Int32($0.minX), Int32($0.minY), Int32($0.maxX), Int32($0.maxY)) }) : nil
        if let occupied { blocked = Set(occupied.map { Cell(x: Int($0.x), y: Int($0.y)) }) }
        else {
            for r in rectangles {
                guard r.minX <= r.maxX && r.minY <= r.maxY else { continue }
                for x in r.minX...r.maxX { for y in r.minY...r.maxY { blocked.insert(Cell(x: x, y: y)) } }
            }
        }
        for edge in graph.edges where edge.source !== edge.target {
            if RoutingCompute.isCancelled { return }
            let start = bestPort(edge.source, other: edge.target, active: edge.sourcePort, candidates: edge.sourcePortCandidates)
            let end = bestPort(edge.target, other: edge.source, active: edge.targetPort, candidates: edge.targetPortCandidates)
            if let path = findPath(start, end, origin: origin, blocked: blocked, usage: usage, source: rect(edge.source.bounds), target: rect(edge.target.bounds)), path.count >= 2 {
                edge.path = simplify(path)
                // The reference accumulates the simplified path's waypoint cells (not every
                // cell along each segment). Preserve that observable congestion behavior.
                if congestionPenalty > 0 { for p in edge.path { usage[cell(p), default: 0] += 1 } }
            } else {
                if RoutingCompute.isCancelled { return }
                edge.path = [start, end]; unroutableEdges.append(edge)
            }
        }
    }
    private func bestPort(_ node: LayoutNode, other: LayoutNode, active: PortConstraint, candidates: [PortConstraint]) -> Point {
        func position(_ side: PortConstraint) -> Point { portPoint(node, side: side) + portDirection(side) }
        if active != .none { return position(active) }
        return candidates.map(position).min { ($0 - other.center).lengthSquared < ($1 - other.center).lengthSquared } ?? node.center
    }
    private func findPath(_ start: Point, _ end: Point, origin: Point, blocked: Set<Cell>, usage: [Cell: Int], source: GridRect, target: GridRect) -> [Point]? {
        func cell(_ p: Point) -> Cell { Cell(x: Int((p.x - origin.x) / Double(gridSize)), y: Int((p.y - origin.y) / Double(gridSize))) }
        func point(_ c: Cell) -> Point { Point(x: origin.x + Double(c.x * gridSize + gridSize / 2), y: origin.y + Double(c.y * gridSize + gridSize / 2)) }
        let a = cell(start), b = cell(end)
        if a == b { return [start, end] }
        let distance = abs(a.x - b.x) + abs(a.y - b.y), radius = max(200, distance * 2)
        let maxIterations = max(10_000, distance * 10)
        func heuristic(_ c: Cell) -> Double { Double(abs(c.x - b.x) + abs(c.y - b.y) + (c.x != b.x && c.y != b.y ? bendPenalty : 0)) }
        let initial = State(cell: a, direction: 0)
        var queue = RoutingPriorityQueue<State>(), closed = Set<State>()
        var costs: [State: Double] = [initial: 0], previous: [State: State] = [:]
        queue.push(initial, priority: heuristic(a))
        var iterations = 0, finish: State?
        while let current = queue.pop() {
            if iterations >= maxIterations || RoutingCompute.isCancelled { break }; iterations += 1
            if !closed.insert(current).inserted { continue }
            if current.cell == b { finish = current; break }
            for (dx, dy, dir) in [(0, 1, 2), (0, -1, 2), (1, 0, 1), (-1, 0, 1)] {
                let c = Cell(x: current.cell.x + dx, y: current.cell.y + dy), next = State(cell: Cell(x: current.cell.x + dx, y: current.cell.y + dy), direction: dir)
                guard abs(c.x - a.x) <= radius, abs(c.y - a.y) <= radius, !closed.contains(next) else { continue }
                if blocked.contains(c) && !source.contains(c) && !target.contains(c) { continue }
                let cost = costs[current]! + 1 + Double(current.direction != 0 && current.direction != dir ? bendPenalty : 0) + Double(congestionPenalty > 0 ? usage[c, default: 0] * congestionPenalty : 0)
                if cost < costs[next, default: .infinity] {
                    costs[next] = cost; previous[next] = current; queue.push(next, priority: cost + heuristic(c))
                }
            }
        }
        guard var current = finish else { return nil }
        var path = [point(current.cell)]
        while let p = previous[current] { current = p; path.append(point(p.cell)) }
        path.reverse()
        insertDogleg(&path, endpoint: start, atStart: true)
        insertDogleg(&path, endpoint: end, atStart: false)
        return path
    }
    private func insertDogleg(_ path: inout [Point], endpoint: Point, atStart: Bool) {
        let grid = atStart ? path[0] : path[path.count - 1]
        let dx = abs(endpoint.x - grid.x), dy = abs(endpoint.y - grid.y)
        if dx < 1e-9 && dy < 1e-9 { path[atStart ? 0 : path.count - 1] = endpoint; return }
        if dx < 1e-9 || dy < 1e-9 {
            if atStart { path.insert(endpoint, at: 0) } else { path.append(endpoint) }; return
        }
        let delta = path.count >= 2 ? (atStart ? path[1] - path[0] : path[path.count - 1] - path[path.count - 2]) : .zero
        let joint = abs(delta.y) > abs(delta.x) ? Point(x: endpoint.x, y: grid.y) : Point(x: grid.x, y: endpoint.y)
        if atStart { path.insert(contentsOf: [endpoint, joint], at: 0) } else { path += [joint, endpoint] }
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

/// Quaternary min-heap with priority-only tie handling, like System.Collections.Generic.PriorityQueue.
/// Router tie handling matters: equally short paths become inputs to later congestion/bundling passes.
struct RoutingPriorityQueue<Value> {
    private var items: [(Value, Double)] = []
    mutating func push(_ value: Value, priority: Double) {
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
