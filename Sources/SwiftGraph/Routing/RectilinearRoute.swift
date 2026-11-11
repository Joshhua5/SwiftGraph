/// Searches for routes made only of horizontal and vertical legs. Orthogonal drawings repair and fall back through
/// these, so a blocked or failed route is replaced without bringing a diagonal into the drawing.
enum RectilinearRoute {
    /// Cost of one bend, in length units.
    static let bendPenalty: Float = 20
    /// The search gives up rather than build a grid with more lines than this across both axes multiplied.
    private static let maximumCells = 250_000

    // MARK: - Routes between ports

    /// A rectilinear route for `edge` that leaves and enters square to the node sides it would use (its port
    /// constraints and candidates honoured), keeping `padding` from other nodes where it can. Nil when none is clear.
    static func route(_ edge: LayoutEdge, _ graph: LayoutGraph, padding: Float, bend: Float = bendPenalty) -> [Point]? {
        guard edge.source !== edge.target else { return nil }
        let flow = OrthogonalPorts.flow(graph).vertical
        let from =
            OrthogonalPorts.ranked(
                edge.source,
                other: edge.target,
                active: edge.sourcePort,
                candidates: edge.sourcePortCandidates,
                vertical: flow
            )
            .prefix(2)
        let to =
            OrthogonalPorts.ranked(
                edge.target,
                other: edge.source,
                active: edge.targetPort,
                candidates: edge.targetPortCandidates,
                vertical: flow
            )
            .prefix(2)
        let obstacles = ObstaclePolyline.obstacles(edge, graph)
        let ends = [edge.source.bounds, edge.target.bounds].filter { $0.width > 0 && $0.height > 0 }
        let interiors = ends.map(ObstaclePolyline.interior)
        func clear(_ path: [Point]) -> Bool {
            ObstaclePolyline.clear(path, obstacles)
                && !zip(path, path.dropFirst()).contains { a, b in interiors.contains { $0.intersectsLine(a, b) } }
        }
        var best: (path: [Point], cost: Float)?
        for a in from {
            for b in to {
                let ps = OrthogonalPorts.point(edge.source, side: a, toward: edge.target.bounds)
                let pt = OrthogonalPorts.point(edge.target, side: b, toward: edge.source.bounds)
                let ds = portDirection(a)
                let dt = portDirection(b)
                // The search runs between stubs just outside each port, so the route leaves and arrives square to its
                // side; a shorter stub is tried when the nodes are too close for the full one.
                for stub in [padding, padding / 4] where stub > 0 {
                    guard
                        let found = search(
                            ps + ds * stub,
                            pt + dt * stub,
                            obstacles + ends,
                            padding: padding,
                            bend: bend
                        )
                    else { continue }
                    let path = compactPath([ps] + found + [pt])
                    guard path.count >= 2, isRectilinear(path), clear(path) else { continue }
                    let cost = ObstaclePolyline.length(path) + bend * Float(path.count - 2)
                    if cost < best?.cost ?? .infinity { best = (path, cost) }
                    break
                }
            }
        }
        return best?.path
    }

    // MARK: - Point to point

    /// The shortest clear route between two points made of horizontal and vertical legs: a straight leg, an L, or a Z
    /// or U through a coordinate half way or just beside an obstacle near the ends; nil when none is clear.
    static func simple(_ a: Point, _ b: Point, _ obstacles: [Rect]) -> [Point]? {
        let area = Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            .inflated(by: 100)
        let near = obstacles.filter { $0.intersects(area) }
        var xs = [(a.x + b.x) / 2]
        var ys = [(a.y + b.y) / 2]
        for r in near {
            xs += [r.left - 10, r.right + 10]
            ys += [r.top - 10, r.bottom + 10]
        }
        var candidates: [[Point]] = [[a, b], [a, Point(x: b.x, y: a.y), b], [a, Point(x: a.x, y: b.y), b]]
        candidates += xs.map { [a, Point(x: $0, y: a.y), Point(x: $0, y: b.y), b] }
        candidates += ys.map { [a, Point(x: a.x, y: $0), Point(x: b.x, y: $0), b] }
        let valid = candidates.map(compactPath).filter { isRectilinear($0) && ObstaclePolyline.clear($0, obstacles) }
        return valid.min { l, r in (l.count, ObstaclePolyline.length(l)) < (r.count, ObstaclePolyline.length(r)) }
    }

    /// The cheapest rectilinear route from `start` to `end` (length plus `bend` per bend) over the grid of lines
    /// through both points, half way between them, and `padding` out from every side of every obstacle. Obstacles
    /// near the two points are searched first, then all of them. Nil when no clear route exists on that grid.
    static func search(
        _ start: Point,
        _ end: Point,
        _ obstacles: [Rect],
        padding: Float,
        bend: Float = bendPenalty
    ) -> [Point]? {
        let solid = obstacles.filter { $0.width > 0 && $0.height > 0 }
        guard !solid.contains(where: { $0.contains(start) || $0.contains(end) }) else { return nil }
        let gap: Float = padding.isFinite ? max(1e-3, padding) : 10
        let span = max(abs(end.x - start.x), abs(end.y - start.y))
        let window = ObstaclePolyline.bounds([start, end]).inflated(by: 4 * gap + span / 2)
        let near = solid.filter { $0.intersects(window) }
        if let path = gridSearch(start, end, near, gap: gap, bend: bend), ObstaclePolyline.clear(path, solid) {
            return path
        }
        guard near.count < solid.count else { return nil }
        return gridSearch(start, end, solid, gap: gap, bend: bend)
    }

    // MARK: - Private

    /// A* over (grid point, direction of arrival), so bends are charged exactly; a route never turns straight back.
    private static func gridSearch(
        _ start: Point,
        _ end: Point,
        _ obstacles: [Rect],
        gap: Float,
        bend: Float
    ) -> [Point]? {
        var xs = [start.x, end.x, (start.x + end.x) / 2]
        var ys = [start.y, end.y, (start.y + end.y) / 2]
        for r in obstacles {
            xs += [r.left - gap, r.right + gap]
            ys += [r.top - gap, r.bottom + gap]
        }
        xs = Array(Set(xs)).sorted()
        ys = Array(Set(ys)).sorted()
        let width = xs.count
        let height = ys.count
        let cells = width * height
        guard cells <= maximumCells,
            let si = xs.firstIndex(of: start.x), let sj = ys.firstIndex(of: start.y),
            let ei = xs.firstIndex(of: end.x), let ej = ys.firstIndex(of: end.y)
        else { return nil }
        let goal = ej * width + ei
        if goal == sj * width + si { return [start, end] }

        let tree = QuadTree<Rect>(
            bounds: Rect(x: xs[0], y: ys[0], width: xs[width - 1] - xs[0], height: ys[height - 1] - ys[0])
                .inflated(by: 1)
        )
        for r in obstacles { tree.insert(bounds: r, item: r) }
        func blocked(_ a: Point, _ b: Point) -> Bool {
            // The tree's overlap test is strict and a few ulps can vanish at large coordinates, so it only narrows
            // the candidates; the closed segment test decides, as `ObstaclePolyline.clear` does.
            let area = ObstaclePolyline.bounds([a, b]).inflated(by: 1)
            return tree.contains(intersecting: area) { r, _ in r.intersectsLine(a, b) }
        }
        // Per cell, whether the step to the next line right (and down) is clear: 0 unknown, 1 clear, 2 blocked.
        var right = [UInt8](repeating: 0, count: cells)
        var down = [UInt8](repeating: 0, count: cells)
        func open(_ cell: Int, horizontal: Bool) -> Bool {
            let known = horizontal ? right[cell] : down[cell]
            if known != 0 { return known == 1 }
            let i = cell % width
            let j = cell / width
            let a = Point(x: xs[i], y: ys[j])
            let b = horizontal ? Point(x: xs[i + 1], y: ys[j]) : Point(x: xs[i], y: ys[j + 1])
            let value: UInt8 = blocked(a, b) ? 2 : 1
            if horizontal { right[cell] = value } else { down[cell] = value }
            return value == 1
        }

        // Directions: 0 right, 1 down, 2 left, 3 up. State = cell * 4 + direction of arrival.
        let steps = [(1, 0), (0, 1), (-1, 0), (0, -1)]
        var cost = [Float](repeating: .infinity, count: cells * 4)
        var previous = [Int](repeating: -1, count: cells * 4)
        var queue = RoutingPriorityQueue<Int>()
        func heuristic(_ cell: Int) -> Float { abs(xs[cell % width] - end.x) + abs(ys[cell / width] - end.y) }
        let first = sj * width + si
        for d in 0..<4 {
            cost[first * 4 + d] = 0
            queue.push(first * 4 + d, priority: heuristic(first))
        }
        var reached: Int?
        var closed = [Bool](repeating: false, count: cells * 4)
        while let state = queue.pop() {
            if RoutingCompute.isCancelled { return nil }
            guard !closed[state] else { continue }
            closed[state] = true
            let cell = state / 4
            let direction = state % 4
            if cell == goal {
                reached = state
                break
            }
            let i = cell % width
            let j = cell / width
            for (d, step) in steps.enumerated() where d != (direction + 2) % 4 {
                let ni = i + step.0
                let nj = j + step.1
                guard ni >= 0, ni < width, nj >= 0, nj < height else { continue }
                let next = nj * width + ni
                let clear =
                    step.1 == 0 ? open(min(cell, next), horizontal: true) : open(min(cell, next), horizontal: false)
                guard clear else { continue }
                let length = abs(xs[ni] - xs[i]) + abs(ys[nj] - ys[j])
                let turn: Float = d == direction || cell == first ? 0 : bend
                let candidate = cost[state] + length + turn
                let target = next * 4 + d
                guard candidate < cost[target] else { continue }
                cost[target] = candidate
                previous[target] = state
                queue.push(target, priority: candidate + heuristic(next))
            }
        }
        guard var state = reached else { return nil }
        var points = [end]
        while previous[state] >= 0 {
            state = previous[state]
            let cell = state / 4
            points.append(Point(x: xs[cell % width], y: ys[cell / width]))
        }
        return compactPath(points.reversed())
    }
}
