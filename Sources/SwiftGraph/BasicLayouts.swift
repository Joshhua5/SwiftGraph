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
        for n in graph.nodes.sorted(by: { $0.id < $1.id }) {
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
        for n in graph.nodes where n.bounds.intersects(clearArea) {
            let distances = [abs(n.bounds.right - clearArea.left), abs(n.x - clearArea.right), abs(n.bounds.bottom - clearArea.top), abs(n.y - clearArea.bottom)]
            let d = distances.min()!
            switch distances.firstIndex(of: d)! {
            case 0: n.x -= d + 10
            case 1: n.x += d + 10
            case 2: n.y -= d + 10
            default: n.y += d + 10
            }
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
        // Compare all preceding rectangles: a wide rectangle can overlap beyond its immediate neighbor.
        let sorted = graph.nodes.enumerated().sorted { a, b in a.element.x == b.element.x ? a.offset < b.offset : a.element.x < b.element.x }.map(\.element)
        for i in sorted.indices {
            if i % 64 == 0 { try Task.checkCancellation() }
            let node = sorted[i]
            for other in sorted[..<i].sorted(by: { $0.x < $1.x }) where node.y < other.bounds.bottom && node.bounds.bottom > other.y {
                if node.x < other.bounds.right + minSpacing && node.bounds.right > other.x { node.x = other.bounds.right + minSpacing }
            }
        }
    }
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
