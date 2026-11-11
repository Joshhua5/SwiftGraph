import Foundation

/// Obstacle-aware visibility search, shared by the polyline router and layout repairs.
enum ObstaclePolyline {
    static let defaultPadding: Float = 10.0

    /// The obstacles of one routing pass, indexed once; a window around each edge is searched first and
    /// widened only when the route found would cut something outside it.
    struct Scene {
        let nodes: [LayoutNode]
        let rects: [Rect]
        let bounds: Rect
        private let tree: QuadTree<Int>
        private let headers: Set<Int>

        init(_ all: [LayoutNode]) {
            let sized = all.filter { $0.bounds.width > 0 && $0.bounds.height > 0 }
            let titled = all.filter { $0.groupTitleBounds != nil }
            nodes = sized + titled
            rects = sized.map(\.bounds) + titled.compactMap(\.groupTitleBounds)
            headers = Set(sized.count..<(sized.count + titled.count))
            bounds = rects.isEmpty ? Rect() : rects.dropFirst().reduce(rects[0]) { $0.union($1) }.inflated(by: 1)
            tree = QuadTree<Int>(bounds: bounds)
            for (i, r) in rects.enumerated() { tree.insert(bounds: r, item: i) }
        }

        /// Every obstacle touching `area`, in index order.
        func within(_ area: Rect) -> [Int] {
            var result: [Int] = []
            tree.forEach(intersecting: area.inflated(by: 1e-5)) { _, i in result.append(i) }
            return result.sorted()
        }

        /// Obstacles of `edge` touching `area`: everything but its own ends and the groups containing them.
        func near(_ area: Rect, _ edge: LayoutEdge) -> [Int] {
            within(area)
                .filter { i in
                    let n = nodes[i]
                    return n !== edge.source && n !== edge.target
                        && !(n.isGroup && !headers.contains(i)
                            && (isAncestor(n, of: edge.source) || isAncestor(n, of: edge.target)))
                }
        }

        func clear(_ path: [Point], _ edge: LayoutEdge) -> Bool {
            guard path.count >= 2 else { return false }
            // Portions hidden inside an endpoint's own box are not visible route cuts.
            let visible = EdgeEndpointClipper.clipped(path, source: edge.source.bounds, target: edge.target.bounds)
            return ObstaclePolyline.clear(
                visible,
                near(ObstaclePolyline.bounds(visible), edge).map { ObstaclePolyline.interior(rects[$0]) }
                    .filter { $0.width > 0 && $0.height > 0 }
            )
        }

        /// As `near`, less a node an endpoint merely sits in (a group centre inside a child), which cannot be avoided.
        fileprivate func relevant(_ area: Rect, _ edge: LayoutEdge, _ start: Point, _ end: Point) -> [Int] {
            func covers(_ r: Rect, _ b: Rect) -> Bool {
                r.left <= b.left && r.right >= b.right && r.top <= b.top && r.bottom >= b.bottom
            }
            let source = edge.source.bounds
            let target = edge.target.bounds
            return near(area, edge)
                .filter { i in
                    let r = rects[i]
                    return !(r.contains(start) && !covers(r, source)) && !(r.contains(end) && !covers(r, target))
                }
        }

        /// Obstacles outside `included` that the route would cut, judged as the search judges them.
        private func violators(_ path: [Point], _ included: Set<Int>, _ edge: LayoutEdge, gap: Float) -> [Int] {
            let start = path[0]
            let end = path[path.count - 1]
            return relevant(ObstaclePolyline.bounds(path).inflated(by: gap), edge, start, end)
                .filter { i in
                    guard !included.contains(i) else { return false }
                    let probe = ObstaclePolyline.probe(rects[i], start, end, gap, straight: path.count == 2)
                    return zip(path, path.dropFirst()).contains { probe.intersectsLine($0, $1) }
                }
        }

        /// The route of `edge` with the padding it was found at and the corners it bends at; nil when no clear route
        /// exists. Padding is halved, quartered and finally cut to about 1 when padded obstacles seal a corridor.
        /// `corners` holds the bends already at each padded corner, and `fan` is how far apart later ones are spread.
        func route(
            _ edge: LayoutEdge,
            padding: Float,
            bend: Float = 0,
            crossing: Float = 0,
            routed: SegmentIndex? = nil,
            corners: [Point: [Bend]] = [:],
            fan: Float = 0,
            comparePadding: Bool = true
        ) -> (path: [Point], gap: Float, bends: [Bend])? {
            let start = edge.source.center
            let end = edge.target.center
            let gap: Float = padding.isFinite ? max(1e-5, padding) : 10
            var ladder = [gap]
            if comparePadding {
                for g in [gap / 2, gap / 4, Float(1.0)] where g < ladder[ladder.count - 1] { ladder.append(g) }
            }
            let window = ObstaclePolyline.bounds([start, end]).inflated(by: 2 * gap + (end - start).length / 4)
            let initial = Set(relevant(window, edge, start, end))
            var extra: ((Point, Point) -> Float)?
            if let routed, crossing > 0 { extra = { a, b in crossing * Float(routed.crossings(a, b)) } }
            for level in ladder {
                var included = initial
                while true {
                    guard
                        let path = ObstaclePolyline.search(
                            start,
                            end,
                            included.sorted().map { rects[$0] },
                            padding: level,
                            bend: bend,
                            extra: extra
                        )
                    else { break }
                    let more = violators(path, included, edge, gap: level)
                    if more.isEmpty {
                        let length = ObstaclePolyline.length(path)
                        let limit = 4 * max(1, (end - start).length)
                        if comparePadding && length > limit {
                            var best: (path: [Point], gap: Float, bends: [Bend])?
                            // A wide padded corridor may be clear but much longer than
                            // a narrower one. Compare without crossing costs as well.
                            for alternative in ladder
                            where alternative <= level && (alternative < level || crossing > 0) {
                                if let short = route(edge, padding: alternative, bend: bend, comparePadding: false),
                                    clear(short.path, edge),
                                    ObstaclePolyline.length(short.path)
                                        < min(length * 0.75, best.map { ObstaclePolyline.length($0.path) } ?? .infinity)
                                {
                                    best = short
                                    if ObstaclePolyline.length(short.path) <= limit { break }
                                }
                            }
                            if let best { return best }
                        }
                        let bends = path.indices.dropFirst().dropLast()
                            .map {
                                Bend(corner: path[$0], toward: path[$0 - 1] - path[$0], away: path[$0 + 1] - path[$0])
                            }
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
        private func spread(
            _ path: [Point],
            _ corners: [Point: [Bend]],
            _ edge: LayoutEdge,
            _ routed: SegmentIndex?,
            gap: Float,
            step: Float
        ) -> [Point] {
            var path = path
            let start = path[0]
            let end = path[path.count - 1]
            func crossings(_ p: [Point]) -> Int {
                routed.map { index in zip(p, p.dropFirst()).reduce(0) { $0 + index.crossings($1.0, $1.1) } } ?? 0
            }
            for k in 1..<path.count - 1 {
                let corner = path[k]
                let mine = Bend(corner: corner, toward: path[k - 1] - corner, away: path[k + 1] - corner)
                let count = corners[corner, default: []].filter { !$0.runsWith(mine) }.count
                guard count > 0 else { continue }
                let a = path[k - 1] - corner
                let b = path[k + 1] - corner
                guard a.length > 0, b.length > 0 else { continue }
                let inward = a / a.length + b / b.length
                guard inward.length > 1e-6 else { continue }
                let outward = inward / -inward.length
                let crossed = crossings(path)
                for n in stride(from: min(count, 4), through: 1, by: -1) {
                    var trial = path
                    trial[k] = corner + outward * (step * Float(n))
                    if relevant(ObstaclePolyline.bounds(trial).inflated(by: gap), edge, start, end)
                        .allSatisfy({ i in
                            let probe = ObstaclePolyline.probe(rects[i], start, end, gap, straight: true)
                            return !zip(trial, trial.dropFirst()).contains { probe.intersectsLine($0, $1) }
                        }) && crossings(trial) <= crossed
                    {
                        path = trial
                        break
                    }
                }
            }
            return path
        }
    }

    static func length(_ path: [Point]) -> Float {
        zip(path, path.dropFirst()).reduce(Float(0)) { $0 + ($1.1 - $1.0).length }
    }

    /// An edge bending at a padded corner, by the directions it comes from and leaves towards.
    struct Bend: Equatable {
        var corner: Point
        var toward: Point
        var away: Point

        /// Whether `other` arrives and leaves the same way (or the reverse), so a separator lane rather than a corner
        /// offset serves it.
        func runsWith(_ other: Bend) -> Bool {
            func close(_ a: Point, _ b: Point) -> Bool {
                abs(a.x * b.y - a.y * b.x) <= Float(sin(5 * Double.pi / 180)) * a.length * b.length
                    && a.x * b.x + a.y * b.y > 0
            }
            return close(toward, other.toward) && close(away, other.away)
                || close(toward, other.away) && close(away, other.toward)
        }
    }

    /// Routed segments by owning edge, queried for how many a candidate segment properly crosses.
    /// A uniform grid over the routing bounds lists each segment in every cell its line passes through (border cells
    /// extend outwards without limit), so two segments that cross always share the cell holding the crossing point.
    /// Unlike a bounding-box tree, a long diagonal costs only the cells it runs through.
    final class SegmentIndex {
        private var segments: [(a: Point, b: Point)] = []
        private var alive: [Bool] = []
        private var byOwner: [Int: [Int]] = [:]
        private var cells: [[Int]]

        /// Per-segment query stamps, so a segment listed in several visited cells is counted once.
        private var stamps: [Int] = []
        private var query = 0
        private let origin: Point
        private let cellWidth: Float
        private let cellHeight: Float
        private let side: Int
        private let slack: Float

        init(bounds: Rect, side: Int = 64) {
            self.side = side
            origin = Point(x: bounds.x, y: bounds.y)
            cellWidth = bounds.width > 0 ? bounds.width / Float(side) : 1
            cellHeight = bounds.height > 0 ? bounds.height / Float(side) : 1
            // Absorbs rounding in the slab clipping; extra cells only cost time, never a missed crossing.
            slack = max(cellWidth, cellHeight) * 0.05
            cells = Array(repeating: [], count: side * side)
        }

        private func cell(_ value: Float, _ start: Float, _ size: Float) -> Int {
            let t = ((value - start) / size).rounded(.down)
            guard t.isFinite else { return t > 0 ? side - 1 : 0 }
            return Int(min(max(t, 0), Float(side - 1)))
        }

        /// Every cell the segment passes through: per row, the segment clipped to that row's slab.
        private func visit(_ a: Point, _ b: Point, _ body: (Int) -> Void) {
            let firstRow = cell(min(a.y, b.y) - slack, origin.y, cellHeight)
            let lastRow = cell(max(a.y, b.y) + slack, origin.y, cellHeight)
            // Non-finite input can order the bounds the wrong way round; it cannot cross anything properly.
            for row in firstRow...max(firstRow, lastRow) {
                var low: Float = -.infinity
                var high: Float = .infinity
                if row > 0 { low = origin.y + Float(row) * cellHeight - slack }
                if row < side - 1 { high = origin.y + Float(row + 1) * cellHeight + slack }
                var x0 = min(a.x, b.x)
                var x1 = max(a.x, b.x)
                if b.y != a.y {
                    let t0 = min(1, max(0, (low - a.y) / (b.y - a.y)))
                    let t1 = min(1, max(0, (high - a.y) / (b.y - a.y)))
                    let p = a.x + (b.x - a.x) * t0
                    let q = a.x + (b.x - a.x) * t1
                    x0 = min(p, q)
                    x1 = max(p, q)
                }
                let first = cell(x0 - slack, origin.x, cellWidth)
                let last = cell(x1 + slack, origin.x, cellWidth)
                for column in first...max(first, last) { body(row * side + column) }
            }
        }

        func add(_ path: [Point], owner: Int) {
            for (a, b) in zip(path, path.dropFirst()) {
                let index = segments.count
                segments.append((a, b))
                alive.append(true)
                stamps.append(0)
                byOwner[owner, default: []].append(index)
                visit(a, b) { cells[$0].append(index) }
            }
        }

        func remove(owner: Int) {
            for i in byOwner.removeValue(forKey: owner) ?? [] {
                alive[i] = false
                // Dead entries would otherwise stay in every cell list they were added to.
                let (a, b) = segments[i]
                visit(a, b) { c in if let k = cells[c].lastIndex(of: i) { cells[c].remove(at: k) } }
            }
        }

        func crossings(_ a: Point, _ b: Point) -> Int {
            func side(_ p: Point, _ q: Point, _ r: Point) -> Float {
                (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
            }
            query += 1
            // The detour search calls this for every relaxed visibility edge; local copies and raw buffers
            // keep the inner loop free of per-element exclusivity checks and retains.
            let query = query
            let cells = cells
            let alive = alive
            let segments = segments
            var count = 0
            segments.withUnsafeBufferPointer { segments in
                alive.withUnsafeBufferPointer { alive in
                    stamps.withUnsafeMutableBufferPointer { stamps in
                        visit(a, b) { c in
                            cells[c]
                                .withUnsafeBufferPointer { list in
                                    for i in list where alive[i] && stamps[i] != query {
                                        stamps[i] = query
                                        let (c, d) = segments[i]
                                        // The second pair of sides only matters once the first pair straddles.
                                        guard side(a, b, c) * side(a, b, d) < -1e-5 else { continue }
                                        if side(c, d, a) * side(c, d, b) < -1e-5 { count += 1 }
                                    }
                                }
                        }
                    }
                }
            }
            return count
        }
    }

    /// The detour search's own measure of a path: length, bends and crossings.
    static func cost(_ path: [Point], bend: Float, crossing: Float, routed: SegmentIndex) -> Float {
        var total: Float = 0.0
        for (k, (a, b)) in zip(path, path.dropFirst()).enumerated() {
            total += (b - a).length + crossing * Float(routed.crossings(a, b))
            if bend > 0, k > 0 { total += bend * turn(path[k - 1], a, b) / .pi }
        }
        return total
    }

    static func turn(_ a: Point, _ b: Point, _ c: Point) -> Float {
        let u = b - a
        let v = c - b
        return atan2(abs(u.x * v.y - u.y * v.x), u.x * v.x + u.y * v.y)
    }

    static func bounds(_ path: [Point]) -> Rect {
        let xs = path.map(\.x)
        let ys = path.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return Rect() }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func obstacles(_ edge: LayoutEdge, _ graph: LayoutGraph) -> [Rect] {
        let bodies = graph.nodes
            .filter {
                $0 !== edge.source && $0 !== edge.target
                    && !($0.isGroup && (isAncestor($0, of: edge.source) || isAncestor($0, of: edge.target)))
            }
            .map(\.bounds)
        let headers = graph.nodes.compactMap { $0 !== edge.source && $0 !== edge.target ? $0.groupTitleBounds : nil }
        return (bodies + headers).filter { $0.width > 0 && $0.height > 0 }
    }

    static func interior(_ rect: Rect) -> Rect {
        let magnitude = [rect.left, rect.right, rect.top, rect.bottom].map(abs).max() ?? 0
        return rect.inflated(by: -min(min(rect.width, rect.height) / 4, max(1e-4, magnitude.ulp * 2)))
    }

    static func clear(_ path: [Point], _ obstacles: [Rect]) -> Bool {
        if let compute = RoutingCompute.current {
            return path.count >= 2 && compute.hits(path, obstacles).isEmpty
        }
        return path.count >= 2
            && !zip(path, path.dropFirst())
                .contains { a, b in
                    obstacles.contains { $0.intersectsLine(a, b) }
                }
    }

    /// Near endpoints a route may need less padding, but never less body clearance.
    private static func clearance(_ r: Rect, _ start: Point, _ end: Point, _ gap: Float) -> Float {
        func distance(_ p: Point) -> Float {
            max(0, max(max(r.left - p.x, p.x - r.right), max(r.top - p.y, p.y - r.bottom)))
        }
        return min(gap, min(distance(start), distance(end)) / 2)
    }

    /// What a route must stay out of: the padded obstacle, or for a straight line half the padding.
    private static func probe(_ r: Rect, _ start: Point, _ end: Point, _ gap: Float, straight: Bool) -> Rect {
        let c = clearance(r, start, end, gap)
        return straight ? r.inflated(by: c / 2) : interior(r.inflated(by: c))
    }

    /// Shortest path (A* over the visibility graph of padded corners) that keeps the padding clear of `obstacles`.
    /// A straight line needs only half the padding. `bend` charges a half-turn and `extra` a segment (never negative);
    /// both default to nothing.
    static func search(
        _ start: Point,
        _ end: Point,
        _ obstacles: [Rect],
        padding: Float,
        bend: Float = 0,
        extra: ((Point, Point) -> Float)? = nil
    ) -> [Point]? {
        guard !obstacles.contains(where: { $0.contains(start) || $0.contains(end) }) else { return nil }
        let gap: Float = padding.isFinite ? max(1e-5, padding) : 10
        if clear([start, end], obstacles.map { $0.inflated(by: clearance($0, start, end, gap) / 2) }) {
            return [start, end]
        }
        var points = [start, end]
        var seen: Set<Point> = [start, end]
        let expanded = obstacles.map { probe($0, start, end, gap, straight: false) }
        let padded = obstacles.map { $0.inflated(by: clearance($0, start, end, gap)) }
        let tree = QuadTree<Rect>(bounds: expanded.dropFirst().reduce(expanded[0]) { $0.union($1) }.inflated(by: 1))
        for r in expanded { tree.insert(bounds: r, item: r) }
        // The tree only finds rects with area; a degenerate one would be missed, so then scan them all.
        let indexed = expanded.allSatisfy { $0.width > 0 && $0.height > 0 }
        func covered(_ p: Point) -> Bool {
            guard indexed else { return expanded.contains { $0.contains(p) } }
            // Inflated so rects whose closed edge touches `p` still intersect the probe; `contains` decides.
            let area = Rect(x: p.x, y: p.y, width: 0, height: 0).inflated(by: max(1e-3, max(abs(p.x), abs(p.y)) * 1e-5))
            return tree.contains(intersecting: area) { r, _ in r.contains(p) }
        }
        points.reserveCapacity(2 + 4 * padded.count)
        for r in padded {
            if RoutingCompute.isCancelled { return nil }
            for point in [
                Point(x: r.left, y: r.top), Point(x: r.right, y: r.top),
                Point(x: r.right, y: r.bottom), Point(x: r.left, y: r.bottom),
            ] {
                if !covered(point), seen.insert(point).inserted { points.append(point) }
            }
        }
        func visible(_ a: Point, _ b: Point) -> Bool {
            let area = Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                .inflated(by: 1e-5)
            return !tree.contains(intersecting: area) { r, _ in r.intersectsLine(a, b) }
        }
        let heuristic = points.map { ($0 - end).length }
        // A bend is charged at its corner, so its cost depends on the arrival as well as the corner. With a bend
        // penalty a state is (corner, the corner it was reached from); without one, the corner alone.
        // An arrival is dropped when another at the same corner costs less by at least `bend` times the angle
        // between their directions (over pi): every later turn differs by at most that angle, so continuing from
        // the other is never worse. Only near-ties in clearly different directions survive, which keeps the state
        // count close to the corner count rather than the visibility-edge count.
        let isBendAware = bend > 0
        let count = points.count
        var vertexOf: [Int] = []
        var parentOf: [Int] = []
        var costOf: [Float] = []
        var heading: [Point] = []
        var statesAt = Array(repeating: [Int](), count: count)
        var best = Array(repeating: Float.infinity, count: count)
        // Several states at one corner may test the same segment; visibility and `extra` depend only on the
        // segment, so with a bend penalty each is worked out once.
        var sight: [Int: Bool] = [:]
        var surcharge: [Int: Float] = [:]
        func slack(_ vertex: Int) -> Float { isBendAware && vertex != 1 ? bend : 0 }
        /// What arriving along `a` rather than `b` can save on any later turn at `vertex`.
        func margin(_ vertex: Int, _ a: Point, _ b: Point) -> Float {
            guard isBendAware, vertex != 1 else { return 0 }
            return bend * atan2(abs(a.x * b.y - a.y * b.x), a.x * b.x + a.y * b.y) / .pi
        }
        func sees(_ a: Int, _ b: Int) -> Bool {
            guard isBendAware else { return visible(points[a], points[b]) }
            if let known = sight[a * count + b] { return known }
            let result = visible(points[a], points[b])
            sight[a * count + b] = result
            return result
        }
        func charge(_ extra: (Point, Point) -> Float, _ a: Int, _ b: Int) -> Float {
            guard isBendAware else { return extra(points[a], points[b]) }
            if let known = surcharge[a * count + b] { return known }
            let result = extra(points[a], points[b])
            surcharge[a * count + b] = result
            return result
        }
        // Binary min-heap on (estimate, corner, state): the lower corner, then the earlier state, wins ties.
        var heap: [(Float, Int, Int)] = []
        func before(_ a: (Float, Int, Int), _ b: (Float, Int, Int)) -> Bool {
            if a.0 != b.0 { return a.0 < b.0 }
            return a.1 != b.1 ? a.1 < b.1 : a.2 < b.2
        }
        func push(_ item: (Float, Int, Int)) {
            heap.append(item)
            var c = heap.count - 1
            while c > 0, before(heap[c], heap[(c - 1) / 2]) {
                heap.swapAt(c, (c - 1) / 2)
                c = (c - 1) / 2
            }
        }
        func pop() -> (Float, Int, Int)? {
            guard let top = heap.first else { return nil }
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var c = 0
                while true {
                    var m = c
                    let left = 2 * c + 1
                    let right = left + 1
                    if left < heap.count && before(heap[left], heap[m]) { m = left }
                    if right < heap.count && before(heap[right], heap[m]) { m = right }
                    if m == c { break }
                    heap.swapAt(c, m)
                    c = m
                }
            }
            return top
        }
        vertexOf.append(0)
        parentOf.append(-1)
        costOf.append(0)
        heading.append(Point(x: 0, y: 0))
        statesAt[0] = [0]
        best[0] = 0
        push((heuristic[0], 0, 0))
        while let (estimate, current, state) = pop() {
            if RoutingCompute.isCancelled { return nil }
            let reached = costOf[state]
            if estimate > reached + heuristic[current] + 1e-4 || reached > best[current] + slack(current) { continue }
            // A cheaper arrival found since this one was queued may now make it redundant.
            let isDominated = isBendAware && statesAt[current].contains { other in
                other != state && costOf[other] + margin(current, heading[other], heading[state]) < reached - 1e-5
            }
            if isDominated { continue }
            if current == 1 {
                var result: [Point] = []
                var at = state
                while at >= 0 {
                    result.append(points[vertexOf[at]])
                    at = parentOf[at]
                }
                return result.reversed()
            }
            let from = parentOf[state] >= 0 ? vertexOf[parentOf[state]] : -1
            for next in points.indices where next != current && next != from {
                var candidate = reached + (points[current] - points[next]).length
                guard candidate < best[next] + slack(next) else { continue }
                let direction = points[next] - points[current]
                // Also covers the state this arrival would replace, whose direction is the same.
                func loses(_ candidate: Float) -> Bool {
                    statesAt[next].contains { candidate >= costOf[$0] + margin(next, heading[$0], direction) }
                }
                guard !loses(candidate), sees(current, next) else { continue }
                if bend > 0, from >= 0 {
                    candidate += bend * turn(points[from], points[current], points[next]) / .pi
                }
                // `extra` is never negative, so it cannot rescue a candidate that already loses.
                if let extra, !loses(candidate) { candidate += charge(extra, current, next) }
                guard !loses(candidate) else { continue }
                let existing = statesAt[next].first { other in
                    !isBendAware || parentOf[other] >= 0 && vertexOf[parentOf[other]] == current
                }
                let target: Int
                if let existing {
                    target = existing
                    costOf[existing] = candidate
                    parentOf[existing] = state
                } else {
                    target = vertexOf.count
                    statesAt[next].append(target)
                    vertexOf.append(next)
                    parentOf.append(state)
                    costOf.append(candidate)
                    heading.append(direction)
                }
                best[next] = min(best[next], candidate)
                push((candidate + heuristic[next], next, target))
            }
        }
        return nil
    }

    /// Re-routes every edge (or `edges`) whose path cuts a node, at the router's `padding`. An edge with no clear
    /// route keeps its path, or a straight line if it has none, and is returned so callers can report it. Detoured
    /// edges are then separated by `spacing`.
    @discardableResult
    static func repair(
        _ graph: LayoutGraph,
        edges: [LayoutEdge]? = nil,
        padding: Float = defaultPadding,
        spacing: Float = 10,
        shortenDetours: Bool = false
    ) -> [LayoutEdge] {
        let scene = Scene(graph.nodes)
        var detoured: [LayoutEdge] = []
        var failed: [LayoutEdge] = []
        for edge in (edges ?? graph.edges) where edge.source !== edge.target {
            if RoutingCompute.isCancelled { return failed }
            let clear = scene.clear(edge.path, edge)
            let length = ObstaclePolyline.length(edge.path)
            let longDetour =
                shortenDetours && clear && length > 4 * max(1, (edge.target.center - edge.source.center).length)
            if clear && !longDetour { continue }
            let found = scene.route(edge, padding: padding)
            if RoutingCompute.isCancelled { return failed }
            if let found, scene.clear(found.path, edge) {
                if !longDetour || ObstaclePolyline.length(found.path) < length * 0.75 {
                    edge.path = found.path
                    detoured.append(edge)
                }
            } else if !clear {
                failed.append(edge)
                if edge.path.count < 2 { edge.path = [edge.source.center, edge.target.center] }
            }
        }
        if spacing > 0, detoured.count > 1 {
            let separator = EdgeSeparator()
            separator.spacing = spacing
            separator.separate(detoured, scene)
        }
        return failed
    }
}
