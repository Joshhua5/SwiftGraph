import Foundation

extension DirectedRouter {
    /// Rasterize exact-coordinate visibility links once per repair search. Obstacle and
    /// occupied-track costs are then O(1) per A* step, rather than scanning every edge.
    private func prepareGrid(
        xs: [Float],
        ys: [Float],
        obstacles: [Rect]
    ) throws -> (horizontal: [Float], vertical: [Float]) {
        let width = xs.count
        let count = width * ys.count
        var horizontal = Array(repeating: Float(0), count: count)
        var vertical = horizontal
        func lower(_ values: [Float], _ value: Float) -> Int {
            var low = 0
            var high = values.count
            while low < high {
                let mid = (low + high) / 2
                if values[mid] < value { low = mid + 1 } else { high = mid }
            }
            return low
        }
        func points(_ values: [Float], _ low: Float, _ high: Float) -> Range<Int> {
            let first = lower(values, low + DirectedGeometry.epsilon)
            return first..<max(first, lower(values, high - DirectedGeometry.epsilon))
        }
        func links(_ values: [Float], _ low: Float, _ high: Float) -> Range<Int> {
            let first = max(0, lower(values, low + DirectedGeometry.epsilon) - 1)
            return first..<max(first, min(values.count - 1, lower(values, high - DirectedGeometry.epsilon)))
        }
        for rect in obstacles {
            try Task.checkCancellation()
            for y in points(ys, rect.top, rect.bottom) {
                for x in links(xs, rect.left, rect.right) { horizontal[y * width + x] = .infinity }
            }
            for x in points(xs, rect.left, rect.right) {
                for y in links(ys, rect.top, rect.bottom) { vertical[y * width + x] = .infinity }
            }
        }
        let window = Rect(x: xs[0], y: ys[0], width: xs[xs.count - 1] - xs[0], height: ys[ys.count - 1] - ys[0])
            .inflated(by: spacing)
        for (i, segment) in occupied.segments.enumerated() {
            if i % 128 == 0 { try Task.checkCancellation() }
            if max(segment.a.x, segment.b.x) < window.left || min(segment.a.x, segment.b.x) > window.right
                || max(segment.a.y, segment.b.y) < window.top || min(segment.a.y, segment.b.y) > window.bottom
            {
                continue
            }
            if segment.horizontal {
                for y in points(ys, segment.a.y - spacing, segment.a.y + spacing) {
                    for x in links(xs, min(segment.a.x, segment.b.x), max(segment.a.x, segment.b.x)) {
                        horizontal[y * width + x] = .infinity
                    }
                }
                let row = lower(ys, segment.a.y)
                for x in points(xs, min(segment.a.x, segment.b.x), max(segment.a.x, segment.b.x)) {
                    if row > 0 { vertical[(row - 1) * width + x] += 350 }
                    if row < ys.count - 1 && ys[row] == segment.a.y { vertical[row * width + x] += 350 }
                }
            } else {
                for x in points(xs, segment.a.x - spacing, segment.a.x + spacing) {
                    for y in links(ys, min(segment.a.y, segment.b.y), max(segment.a.y, segment.b.y)) {
                        vertical[y * width + x] = .infinity
                    }
                }
                let column = lower(xs, segment.a.x)
                for y in points(ys, min(segment.a.y, segment.b.y), max(segment.a.y, segment.b.y)) {
                    if column > 0 { horizontal[y * width + column - 1] += 350 }
                    if column < width - 1 && xs[column] == segment.a.x { horizontal[y * width + column] += 350 }
                }
            }
        }
        return (horizontal, vertical)
    }

    /// The main pass searches a window around the endpoints that widens only when the
    /// narrower one fails; every grid is capped. `startAxis`/`endAxis` (1 horizontal, 2 vertical)
    /// seed the first direction and price a bend at the arrival, as the port approaches are fixed.
    func search(
        from start: Point,
        to end: Point,
        startAxis: Int,
        endAxis: Int,
        occupiedCoordinates: Bool = false,
        visitLimit: Int? = nil
    ) throws -> [Point]? {
        let margins: [Float] = visitLimit == nil ? [96, 384, .infinity] : [.infinity]
        let cap = visitLimit == nil ? 262_144 : 65_536
        let box = Rect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )
        var lastShape = (0, 0)
        for margin in margins {
            let window = margin.isFinite ? box.inflated(by: margin) : nil
            let local = window.map { w in obstacles.filter { $0.inflated(by: 1).intersects(w) } } ?? obstacles
            var xs = local.flatMap { [$0.left - 1, $0.right + 1] } + [start.x, end.x]
            var ys = local.flatMap { [$0.top - 1, $0.bottom + 1] } + [start.y, end.y]
            if occupiedCoordinates {
                xs += occupied.segments.filter { !$0.horizontal }.flatMap { [$0.a.x - spacing, $0.a.x + spacing] }
                ys += occupied.segments.filter(\.horizontal).flatMap { [$0.a.y - spacing, $0.a.y + spacing] }
            }
            if let window {
                xs += [window.left, window.right]
                ys += [window.top, window.bottom]
            }
            let xv = Array(Set(window.map { w in xs.filter { $0 >= w.left && $0 <= w.right } } ?? xs)).sorted()
            let yv = Array(Set(window.map { w in ys.filter { $0 >= w.top && $0 <= w.bottom } } ?? ys)).sorted()
            if (xv.count, yv.count) == lastShape { continue }
            lastShape = (xv.count, yv.count)
            if xv.count * yv.count > cap { return nil }
            if let path = try search(
                xs: xv,
                ys: yv,
                obstacles: local,
                from: start,
                to: end,
                startAxis: startAxis,
                endAxis: endAxis,
                visitLimit: visitLimit
            ) {
                return path
            }
        }
        return nil
    }

    func search(
        xs: [Float],
        ys: [Float],
        obstacles local: [Rect],
        from start: Point,
        to end: Point,
        startAxis: Int,
        endAxis: Int,
        visitLimit: Int?
    ) throws -> [Point]? {
        let width = xs.count
        let height = ys.count
        let cells = width * height
        let goal = cells * 3
        guard
            let startY = ys.firstIndex(of: start.y),
            let startX = xs.firstIndex(of: start.x),
            let endY = ys.firstIndex(of: end.y),
            let endX = xs.firstIndex(of: end.x)
        else {
            preconditionFailure("Search endpoints must lie on the grid lines built by prepareGrid")
        }
        let first = startY * width + startX
        let last = endY * width + endX
        // The work buffers are moved out of the router for the loop and handed back afterwards.
        var costs = self.costs
        var previous = self.previous
        var closed = self.closed
        self.costs = []
        self.previous = []
        self.closed = []
        defer {
            self.costs = costs
            self.previous = previous
            self.closed = closed
        }
        if costs.count < goal + 1 {
            costs = [Float](repeating: .infinity, count: goal + 1)
            previous = [Int](repeating: -1, count: goal + 1)
            closed = [Bool](repeating: false, count: goal + 1)
        } else {
            for i in 0...goal {
                costs[i] = .infinity
                previous[i] = -1
                closed[i] = false
            }
        }
        var queue = DirectedMinHeap()
        let grid = try prepareGrid(xs: xs, ys: ys, obstacles: local)
        let initial = first * 3 + startAxis
        costs[initial] = 0
        queue.push(initial, priority: abs(start.x - end.x) + abs(start.y - end.y))
        var visited = 0
        let steps = [(1, 0, 1), (-1, 0, 1), (0, 1, 2), (0, -1, 2)]
        while let current = queue.pop() {
            visited += 1
            if let visitLimit, visited > visitLimit { return nil }
            if visited % 128 == 0 { try Task.checkCancellation() }
            if closed[current] { continue }
            closed[current] = true
            if current == goal {
                var at = previous[current]
                var path: [Point] = []
                while at != -1 {
                    let cell = at / 3
                    path.append(Point(x: xs[cell % width], y: ys[cell / width]))
                    at = previous[at]
                }
                return DirectedGeometry.compact(path.reversed())
            }
            let cell = current / 3
            let direction = current % 3
            if cell == last {
                let cost = costs[current] + (direction != endAxis ? 24 : 0)
                if cost < costs[goal] {
                    costs[goal] = cost
                    previous[goal] = current
                    queue.push(goal, priority: cost)
                }
                continue
            }
            let x = cell % width
            let y = cell / width
            let base = costs[current]
            for (dx, dy, nextDirection) in steps {
                let nx = x + dx
                let ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let nextCell = ny * width + nx
                let next = nextCell * 3 + nextDirection
                let congestion = dy == 0 ? grid.horizontal[min(cell, nextCell)] : grid.vertical[min(cell, nextCell)]
                let cost =
                    base + abs(xs[x] - xs[nx]) + abs(ys[y] - ys[ny]) + congestion
                    + (direction != 0 && direction != nextDirection ? 24 : 0)
                if cost < costs[next] {
                    costs[next] = cost
                    previous[next] = current
                    queue.push(next, priority: cost + abs(xs[nx] - end.x) + abs(ys[ny] - end.y))
                }
            }
        }
        return nil
    }
}

private struct DirectedMinHeap {
    private var values: [(state: Int, priority: Float)] = []

    mutating func push(_ state: Int, priority: Float) {
        values.append((state, priority))
        var i = values.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard less(i, parent) else { break }
            values.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> Int? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast().state }
        let result = values[0].state
        values[0] = values.removeLast()
        var i = 0
        while i * 2 + 1 < values.count {
            var child = i * 2 + 1
            if child + 1 < values.count && less(child + 1, child) { child += 1 }
            guard less(child, i) else { break }
            values.swapAt(child, i)
            i = child
        }
        return result
    }

    private func less(_ a: Int, _ b: Int) -> Bool {
        values[a].priority == values[b].priority
            ? values[a].state < values[b].state : values[a].priority < values[b].priority
    }
}
