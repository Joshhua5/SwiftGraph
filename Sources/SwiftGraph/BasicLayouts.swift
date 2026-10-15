import Foundation

public final class CircularLayoutAlgorithm: LayoutAlgorithm {
    public var radius: Float = 300
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let nodes = graph.nodes.filter { !$0.isGroup }
        guard !nodes.isEmpty else { return }
        let fitted = fittedCirclePlacement(nodes.map(\.bounds), minimum: radius), r = fitted.radius
        for (i, node) in nodes.enumerated() {
            let angle = fitted.angles[i]
            node.center = Point(x: r + 50 + r * cos(angle), y: r + 50 + r * sin(angle))
        }
        straightEdges(graph)
    }
}

public final class TabularLayoutAlgorithm: LayoutAlgorithm {
    public var cellSpacing: Float = 50
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation(); gridLayout(graph, spacing: cellSpacing); straightEdges(graph)
    }
}
func gridLayout(_ graph: LayoutGraph, spacing: Float) {
    let nodes = graph.nodes.filter { !$0.isGroup }
    guard !nodes.isEmpty else { return }
    let columns = Int(ceil(sqrt(Double(nodes.count))))
    let stepX = (nodes.map(\.width).max() ?? 0) + spacing
    let stepY = (nodes.map(\.height).max() ?? 0) + spacing
    for (i, n) in nodes.enumerated() { n.x = Float(i % columns) * stepX; n.y = Float(i / columns) * stepY }
}
public final class OrthogonalLayoutAlgorithm: LayoutAlgorithm {
    public var gridSize: Float = 100
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation(); gridLayout(graph, spacing: gridSize)
        for e in graph.edges where e.source !== e.target {
            let a = e.source.center, b = e.target.center, x = (a.x + b.x) / 2
            e.path = [a, Point(x: x, y: a.y), Point(x: x, y: b.y), b]
        }
    }
}

public final class PartitionGridLayoutAlgorithm: LayoutAlgorithm {
    public var cellAssignment: [String: (row: Int, col: Int)] = [:]
    public var defaultColumnWidth: Float = 150
    public var defaultRowHeight: Float = 100
    public var cellPadding: Float = 20
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let cells = cellAssignment.filter { $0.value.row >= 0 && $0.value.col >= 0 }
        guard !cells.isEmpty, !graph.nodes.isEmpty else { return }
        var heights = Array(repeating: defaultRowHeight, count: cells.values.map(\.row).max()! + 1)
        var widths = Array(repeating: defaultColumnWidth, count: cells.values.map(\.col).max()! + 1)
        for n in graph.nodes {
            guard let c = cells[n.id] else { continue }
            heights[c.row] = max(heights[c.row], n.height + cellPadding * 2)
            widths[c.col] = max(widths[c.col], n.width + cellPadding * 2)
        }
        let xs = offsets(widths), ys = offsets(heights)
        for n in graph.nodes {
            guard let c = cells[n.id] else { continue }
            n.center = Point(x: xs[c.col] + widths[c.col] / 2, y: ys[c.row] + heights[c.row] / 2)
        }
        ChannelEdgeRouter().routeEdges(graph)
    }
}
func offsets(_ sizes: [Float], gap: Float = 0) -> [Float] {
    var position: Float = 0.0
    return sizes.map { size in defer { position += size + gap }; return position }
}

public final class KandinskyLayoutAlgorithm: LayoutAlgorithm {
    public var gridPadding: Float = 40
    public var maxCellsPerRow: Int?
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph), layers = a.layers(maxWidth: maxCellsPerRow ?? .max)
        guard let columns = layers.map(\.count).max() else { return }
        var widths = Array(repeating: Float(0.0), count: columns), heights = Array(repeating: Float(0.0), count: layers.count)
        for (r, layer) in layers.enumerated() {
            for (c, i) in layer.enumerated() { widths[c] = max(widths[c], a.nodes[i].width); heights[r] = max(heights[r], a.nodes[i].height) }
        }
        let xs = offsets(widths, gap: gridPadding), ys = offsets(heights, gap: gridPadding)
        for (r, layer) in layers.enumerated() {
            for (c, i) in layer.enumerated() { a.nodes[i].center = Point(x: xs[c] + widths[c] / 2, y: ys[r] + heights[r] / 2) }
        }
        ChannelEdgeRouter().routeEdges(graph)
    }
}

public final class VerticalStackLayoutAlgorithm: LayoutAlgorithm {
    public var spacing: Float = 40
    public var paddingX: Float = 10
    public var paddingY: Float = 10
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        var y = paddingY
        let width = graph.nodes.map(\.width).max() ?? 0
        // Numeric-aware ordering keeps n2 before n10.
        for n in graph.nodes.sorted(by: { $0.id.compare($1.id, options: .numeric) == .orderedAscending }) {
            n.x = paddingX; n.y = y; n.width = width; y += n.height + spacing
        }
    }
}

public enum AlignmentMode: Sendable { case none, left, center, right, top, middle, bottom, snapToGrid }
public final class AlignmentLayoutAlgorithm: LayoutAlgorithm {
    public var horizontalAlignment: AlignmentMode = .none
    public var verticalAlignment: AlignmentMode = .none
    public var gridSize: Float = 20
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let bounds = graph.bounds
        var moved = false
        for n in graph.nodes {
            let old = n.bounds
            switch horizontalAlignment {
            case .left: n.x = bounds.left
            case .right: n.x = bounds.right - n.width
            case .center: n.x = bounds.center.x - n.width / 2
            case .snapToGrid where gridSize > 0: n.x = (n.x / gridSize).rounded(.toNearestOrEven) * gridSize
            default: break
            }
            switch verticalAlignment {
            case .top: n.y = bounds.top
            case .bottom: n.y = bounds.bottom - n.height
            case .middle: n.y = bounds.center.y - n.height / 2
            case .snapToGrid where gridSize > 0: n.y = (n.y / gridSize).rounded(.toNearestOrEven) * gridSize
            default: break
            }
            moved = moved || n.bounds != old
        }
        if moved { straightEdges(graph) }
    }
}

public final class FillAreaLayoutAlgorithm: LayoutAlgorithm {
    public var fillArea: Rect
    public init(_ areaToFill: Rect = Rect(width: 100, height: 100)) { fillArea = areaToFill }
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let nodes = graph.nodes.filter { !$0.isGroup }, count = nodes.count
        guard count > 0 else { return }
        let ratio = fillArea.width > 0 && fillArea.height > 0 ? fillArea.width / fillArea.height : 1
        let cols = min(count, max(1, Int(ceil(sqrt(Float(count) * ratio)))))
        let rows = (count + cols - 1) / cols
        let cw = fillArea.width > 0 ? fillArea.width / Float(cols) : 1
        let ch = fillArea.height > 0 ? fillArea.height / Float(rows) : 1
        for (i, n) in nodes.enumerated() {
            n.center = Point(x: fillArea.x + (Float(i % cols) + 0.5) * cw, y: fillArea.y + (Float(i / cols) + 0.5) * ch)
        }
        straightEdges(graph)
    }
}
public final class ClearAreaLayoutAlgorithm: LayoutAlgorithm {
    public var clearArea: Rect
    public init(_ areaToClear: Rect = Rect(width: 100, height: 100)) { clearArea = areaToClear }
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let gap: Float = 10.0
        for n in graph.nodes where n.bounds.intersects(clearArea) {
            let start = n.bounds
            let others = n.isGroup ? [] : graph.nodes.filter { $0 !== n && !$0.isGroup }.map(\.bounds)
            // Leave the area on each side, then keep going past any node the move would land on.
            let moves = [Point(x: clearArea.left - start.right - gap, y: 0), Point(x: clearArea.right - start.left + gap, y: 0),
                         Point(x: 0, y: clearArea.top - start.bottom - gap), Point(x: 0, y: clearArea.bottom - start.top + gap)]
                .enumerated().map { side, initial in
                    var offset = initial
                    while let hit = others.first(where: { start.translated(by: offset).inflated(by: gap - 1e-6).intersects($0) }) {
                        switch side {
                        case 0: offset.x = hit.left - gap - start.right
                        case 1: offset.x = hit.right + gap - start.left
                        case 2: offset.y = hit.top - gap - start.bottom
                        default: offset.y = hit.bottom + gap - start.top
                        }
                    }
                    return offset
                }
            let best = moves.min { abs($0.x) + abs($0.y) < abs($1.x) + abs($1.y) }!
            n.x += best.x; n.y += best.y
        }
        straightEdges(graph)
    }
}
public final class GivenCoordinatesLayoutAlgorithm: LayoutAlgorithm {
    public var edgeRouter: any EdgeRouter = PolylineEdgeRouter()
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws { try Task.checkCancellation(); edgeRouter.routeEdges(graph) }
}
public final class RemoveOverlapsLayoutAlgorithm: LayoutAlgorithm {
    public var minSpacing: Float = 10
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let before = graph.nodes.map(\.bounds)
        defer { followMovedNodes(graph, from: before) }
        let leaves = graph.nodes.filter { !$0.isGroup }
        try forceScan(leaves, spacing: minSpacing)
        // Force scan cannot split nodes with identical centers; separate any such remainder locally.
        if try separateOverlaps(leaves, spacing: minSpacing, movable: leaves.map { _ in true }) { return }
        // Dense clusters can exhaust the pass budget; a rightward sweep always terminates.
        // Compare all preceding rectangles: a wide rectangle can overlap beyond its immediate neighbor.
        let sorted = graph.nodes.enumerated().sorted { a, b in a.element.x == b.element.x ? a.offset < b.offset : a.element.x < b.element.x }.map(\.element)
        for i in sorted.indices {
            if i % 64 == 0 { try Task.checkCancellation() }
            let node = sorted[i]
            for other in sorted[..<i].sorted(by: { $0.x < $1.x }) where node.y < other.bounds.bottom + minSpacing && node.bounds.bottom + minSpacing > other.y {
                if node.x < other.bounds.right + minSpacing && node.bounds.right > other.x { node.x = other.bounds.right + minSpacing }
            }
        }
    }
}

/// Carries routes along with moved nodes: each path's ends follow their nodes (points between blend the two moves, so a
/// rigid move translates the path), and a route left crossing a node is searched afresh between its ends. A route made
/// only of horizontal and vertical legs stays so: its legs slide rigidly, and a search for it tries rectilinear shapes first.
func followMovedNodes(_ graph: LayoutGraph, from old: [Rect]) {
    let moves = zip(graph.nodes, old).map { Point(x: $0.x - $1.x, y: $0.y - $1.y) }
    guard moves.contains(where: { $0 != .zero }) else { return }
    let move = Dictionary(zip(graph.nodes, moves), uniquingKeysWith: { a, _ in a })
    // A lone straight leg only counts as rectilinear in a drawing where every route is and some bend.
    let routed = graph.edges.filter { $0.path.count >= 2 }, orthogonal = routed.allSatisfy { isRectilinear($0.path) } && routed.contains { $0.path.count >= 3 }
    for e in routed {
        let ds = move[e.source] ?? .zero, dt = move[e.target] ?? .zero
        let rectilinear = isRectilinear(e.path) && (e.path.count >= 3 || orthogonal)
        if ds != .zero || dt != .zero { e.path = rectilinear ? carriedRectilinear(e.path, ds, dt) : carried(e.path, ds, dt) }
        guard e.source !== e.target else { continue }
        let obstacles = ObstaclePolyline.obstacles(e, graph)
        guard !ObstaclePolyline.clear(e.path, obstacles) else { continue }
        let start = e.path[0], end = e.path[e.path.count - 1]
        if rectilinear, let found = rectilinearRoute(start, end, obstacles) { e.path = found }
        else if let found = ObstaclePolyline.search(start, end, obstacles, padding: 10) { e.path = found }
    }
}
private func carried(_ path: [Point], _ ds: Point, _ dt: Point) -> [Point] {
    var along: [Float] = [0.0]
    for (a, b) in zip(path, path.dropFirst()) { along.append(along.last! + (b - a).length) }
    return path.indices.map { i in
        let f = along.last! > 0 ? along[i] / along.last! : Float(i) / Float(path.count - 1)
        return path[i] + ds * (1 - f) + dt * f
    }
}
private func isRectilinear(_ path: [Point]) -> Bool {
    zip(path, path.dropFirst()).allSatisfy { abs($0.x - $1.x) < 1e-5 || abs($0.y - $1.y) < 1e-5 }
}
/// Slides the legs of a rectilinear route with the moves of its ends: each leg shifts across itself by the end move at
/// its end of the route (the first and last legs exactly), blending between for the legs in the middle. A single leg
/// whose two ends move differently across it gets a jog half way.
private func carriedRectilinear(_ route: [Point], _ ds: Point, _ dt: Point) -> [Point] {
    let path = compactPath(route)
    guard path.count >= 2 else { return carried(route, ds, dt) }
    let legs = zip(path, path.dropFirst()).map { abs($0.y - $1.y) < 1e-5 }   // true: horizontal, shifts in y
    guard zip(legs, legs.dropFirst()).allSatisfy({ $0 != $1 }) else { return carried(route, ds, dt) }
    let first = path[0] + ds, last = path[path.count - 1] + dt
    if legs.count == 1 {
        if legs[0] ? abs(first.y - last.y) < 1e-5 : abs(first.x - last.x) < 1e-5 { return [first, last] }
        return legs[0] ? [first, Point(x: (first.x + last.x) / 2, y: first.y), Point(x: (first.x + last.x) / 2, y: last.y), last]
                       : [first, Point(x: first.x, y: (first.y + last.y) / 2), Point(x: last.x, y: (first.y + last.y) / 2), last]
    }
    var along: [Float] = [0.0]
    for (a, b) in zip(path, path.dropFirst()) { along.append(along.last! + (b - a).length) }
    let total = max(along.last!, 1e-6)
    let shift = legs.indices.map { j -> Float in
        let f: Float = j == 0 ? 0 : j == legs.count - 1 ? 1 : (along[j] + along[j + 1]) / (2 * total)
        let from = legs[j] ? ds.y : ds.x, to = legs[j] ? dt.y : dt.x
        return from + (to - from) * f
    }
    var result = [first]
    for k in 1..<(path.count - 1) {
        let h = legs[k - 1] ? k - 1 : k, v = legs[k - 1] ? k : k - 1
        result.append(Point(x: path[k].x + shift[v], y: path[k].y + shift[h]))
    }
    return result + [last]
}
/// The shortest clear route between two points made of horizontal and vertical legs: a straight leg, an L, or a Z or U
/// through a coordinate half way or just beside an obstacle near the ends; nil when none is clear.
private func rectilinearRoute(_ a: Point, _ b: Point, _ obstacles: [Rect]) -> [Point]? {
    let area = Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).inflated(by: 100)
    let near = obstacles.filter { $0.intersects(area) }
    var xs = [(a.x + b.x) / 2], ys = [(a.y + b.y) / 2]
    for r in near { xs += [r.left - 10, r.right + 10]; ys += [r.top - 10, r.bottom + 10] }
    var candidates: [[Point]] = [[a, b], [a, Point(x: b.x, y: a.y), b], [a, Point(x: a.x, y: b.y), b]]
    candidates += xs.map { [a, Point(x: $0, y: a.y), Point(x: $0, y: b.y), b] } + ys.map { [a, Point(x: a.x, y: $0), Point(x: b.x, y: $0), b] }
    let valid = candidates.map(compactPath).filter { isRectilinear($0) && ObstaclePolyline.clear($0, obstacles) }
    return valid.min { l, r in
        let a = (l.count, zip(l, l.dropFirst()).reduce(Float(0.0)) { $0 + ($1.1 - $1.0).length }), c = (r.count, zip(r, r.dropFirst()).reduce(Float(0.0)) { $0 + ($1.1 - $1.0).length })
        return a < c
    }
}

/// Force-scan overlap removal (Misue et al. 1995): sweeps each axis in center order and shifts everything
/// beyond a conflict by the same amount, so no left/right or above/below relation between nodes changes.
func forceScan(_ nodes: [LayoutNode], spacing: Float) throws {
    for horizontal in [true, false] {
        try Task.checkCancellation()
        let centers = nodes.map(\.center)
        let key = { (i: Int) in horizontal ? centers[i].x : centers[i].y }
        let order = nodes.indices.sorted { key($0) == key($1) ? $0 < $1 : key($0) < key($1) }
        var i = 0
        while i < order.count {
            var k = i
            while k + 1 < order.count && key(order[k + 1]) == key(order[i]) { k += 1 }
            var shift: Float = 0.0
            for m in order[i...k] {
                for j in order[(k + 1)...] {
                    let a = nodes[m].bounds, b = nodes[j].bounds, d = b.center - a.center
                    let needX = (a.width + b.width) / 2 + spacing, needY = (a.height + b.height) / 2 + spacing
                    guard abs(d.x) < needX - 1e-9 && abs(d.y) < needY - 1e-9 else { continue }
                    // Scale the center offset until either axis clears; this axis takes its component.
                    let t = min(d.x != 0 ? needX / abs(d.x) : .infinity, d.y != 0 ? needY / abs(d.y) : .infinity)
                    shift = max(shift, (horizontal ? d.x : d.y) * (t - 1))
                }
            }
            if shift > 0 {
                for j in order[(k + 1)...] { if horizontal { nodes[j].x += shift } else { nodes[j].y += shift } }
            }
            i = k + 1
        }
    }
}

/// Pushes each pair closer than `spacing` on both axes apart along the axis needing the smaller move,
/// so rows stay rows and columns stay columns. Pairs with one fixed member move only the other;
/// fixed pairs are left alone. Returns false if the pass budget runs out before every pair is clear.
func separateOverlaps(_ nodes: [LayoutNode], spacing: Float, movable: [Bool], passes: Int = 200) throws -> Bool {
    let candidates = nodes.indices.filter { !nodes[$0].isGroup }
    for pass in 0..<passes {
        if pass % 16 == 0 { try Task.checkCancellation() }
        // Window by the pass-start positions; pairs missed after a move are caught by the next pass,
        // and the final, motionless pass is exact.
        let order = candidates.sorted { nodes[$0].x == nodes[$1].x ? $0 < $1 : nodes[$0].x < nodes[$1].x }
        let lefts = order.map { nodes[$0].x }, rights = order.map { nodes[$0].bounds.right }
        var moved = false
        for k in order.indices {
            for m in (k + 1)..<order.count {
                if lefts[m] >= rights[k] + spacing { break }
                let (i, j) = (order[k], order[m])
                guard movable[i] || movable[j] else { continue }
                let a = nodes[i].bounds, b = nodes[j].bounds
                let needX = min(a.right, b.right) - max(a.left, b.left) + spacing
                let needY = min(a.bottom, b.bottom) - max(a.top, b.top) + spacing
                guard needX > 1e-9 && needY > 1e-9 else { continue }
                let horizontal = needX <= needY
                let forward = horizontal ? (a.center.x == b.center.x ? i < j : a.center.x < b.center.x)
                                         : (a.center.y == b.center.y ? i < j : a.center.y < b.center.y)
                let need = horizontal ? needX : needY
                let share = movable[i] && movable[j] ? need / 2 : need
                let step = forward ? share : -share
                if movable[i] { if horizontal { nodes[i].x -= step } else { nodes[i].y -= step } }
                if movable[j] { if horizontal { nodes[j].x += step } else { nodes[j].y += step } }
                moved = true
            }
        }
        if !moved { return true }
    }
    return false
}
public final class CompactDiskLayoutAlgorithm: LayoutAlgorithm {
    public var spacing: Float = 40
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let nodes = graph.nodes.filter { !$0.isGroup }.sorted { $0.width * $0.height > $1.width * $1.height }
        guard !nodes.isEmpty else { return }
        let largest = nodes.prefix(max(1, nodes.count / 2))
        let c = largest.reduce(Float(0.0)) { $0 + max($1.width, $1.height) } / Float(largest.count) / 2 + spacing
        for (i, n) in nodes.enumerated() {
            let r = c * sqrt(Float(i)), angle = Double(i) * .pi * (3 - sqrt(5))
            n.center = Point(x: r * Float(cos(angle)), y: r * Float(sin(angle)))
        }
        straightEdges(graph)
    }
}
