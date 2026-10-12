import Foundation

public final class CircularLayoutAlgorithm: LayoutAlgorithm {
    public var radius: Double = 300
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let nodes = graph.nodes.filter { !$0.isGroup }
        guard !nodes.isEmpty else { return }
        let span = nodes.map { hypot($0.width, $0.height) }.max() ?? 0
        let r = max(radius, Double(nodes.count) * (span + 20) / (2 * .pi))
        for (i, node) in nodes.enumerated() {
            let angle = Double(i) * 2 * .pi / Double(nodes.count)
            node.center = Point(x: r + 50 + r * cos(angle), y: r + 50 + r * sin(angle))
        }
        straightEdges(graph)
    }
}

public final class TabularLayoutAlgorithm: LayoutAlgorithm {
    public var cellSpacing: Double = 50
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation(); gridLayout(graph, spacing: cellSpacing); straightEdges(graph)
    }
}
func gridLayout(_ graph: LayoutGraph, spacing: Double) {
    let nodes = graph.nodes.filter { !$0.isGroup }
    guard !nodes.isEmpty else { return }
    let columns = Int(ceil(sqrt(Double(nodes.count))))
    let stepX = (nodes.map(\.width).max() ?? 0) + spacing
    let stepY = (nodes.map(\.height).max() ?? 0) + spacing
    for (i, n) in nodes.enumerated() { n.x = Double(i % columns) * stepX; n.y = Double(i / columns) * stepY }
}
public final class OrthogonalLayoutAlgorithm: LayoutAlgorithm {
    public var gridSize: Double = 100
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
    public var defaultColumnWidth: Double = 150
    public var defaultRowHeight: Double = 100
    public var cellPadding: Double = 20
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
func offsets(_ sizes: [Double], gap: Double = 0) -> [Double] {
    var position = 0.0
    return sizes.map { size in defer { position += size + gap }; return position }
}

public final class KandinskyLayoutAlgorithm: LayoutAlgorithm {
    public var gridPadding: Double = 40
    public var maxCellsPerRow: Int?
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph), layers = a.layers(maxWidth: maxCellsPerRow ?? .max)
        guard let columns = layers.map(\.count).max() else { return }
        var widths = Array(repeating: 0.0, count: columns), heights = Array(repeating: 0.0, count: layers.count)
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
    public var spacing: Double = 40
    public var paddingX: Double = 10
    public var paddingY: Double = 10
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
    public var gridSize: Double = 20
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
        let cols = min(count, max(1, Int(ceil(sqrt(Double(count) * ratio)))))
        let rows = (count + cols - 1) / cols
        let cw = fillArea.width > 0 ? fillArea.width / Double(cols) : 1
        let ch = fillArea.height > 0 ? fillArea.height / Double(rows) : 1
        for (i, n) in nodes.enumerated() {
            n.center = Point(x: fillArea.x + (Double(i % cols) + 0.5) * cw, y: fillArea.y + (Double(i / cols) + 0.5) * ch)
        }
        straightEdges(graph)
    }
}
public final class ClearAreaLayoutAlgorithm: LayoutAlgorithm {
    public var clearArea: Rect
    public init(_ areaToClear: Rect = Rect(width: 100, height: 100)) { clearArea = areaToClear }
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let gap = 10.0
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
    public var minSpacing: Double = 10
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
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

/// Force-scan overlap removal (Misue et al. 1995): sweeps each axis in center order and shifts everything
/// beyond a conflict by the same amount, so no left/right or above/below relation between nodes changes.
func forceScan(_ nodes: [LayoutNode], spacing: Double) throws {
    for horizontal in [true, false] {
        try Task.checkCancellation()
        let centers = nodes.map(\.center)
        let key = { (i: Int) in horizontal ? centers[i].x : centers[i].y }
        let order = nodes.indices.sorted { key($0) == key($1) ? $0 < $1 : key($0) < key($1) }
        var i = 0
        while i < order.count {
            var k = i
            while k + 1 < order.count && key(order[k + 1]) == key(order[i]) { k += 1 }
            var shift = 0.0
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
func separateOverlaps(_ nodes: [LayoutNode], spacing: Double, movable: [Bool], passes: Int = 200) throws -> Bool {
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
    public var spacing: Double = 40
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let nodes = graph.nodes.filter { !$0.isGroup }.sorted { $0.width * $0.height > $1.width * $1.height }
        guard !nodes.isEmpty else { return }
        let largest = nodes.prefix(max(1, nodes.count / 2))
        let c = largest.reduce(0.0) { $0 + max($1.width, $1.height) } / Double(largest.count) / 2 + spacing
        for (i, n) in nodes.enumerated() {
            let r = c * sqrt(Double(i)), angle = Double(i) * .pi * (3 - sqrt(5))
            n.center = Point(x: r * cos(angle), y: r * sin(angle))
        }
        straightEdges(graph)
    }
}
