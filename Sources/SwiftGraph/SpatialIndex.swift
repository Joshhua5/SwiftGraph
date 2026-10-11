import Foundation

/// Rectangle quadtree. Straddling and out-of-root entries remain in the parent bucket.
public final class QuadTree<Value> {
    private let bounds: Rect
    private let capacity: Int
    private let maxDepth: Int
    private var entries: [(Rect, Value)] = []
    private var children: [QuadTree<Value>] = []
    public init(bounds: Rect, capacity: Int = 32, maxDepth: Int = 8) {
        self.bounds = bounds; self.capacity = max(1, capacity); self.maxDepth = max(0, maxDepth)
    }
    public func insert(bounds rect: Rect, item: Value) {
        if let child = children.first(where: { $0.encloses(rect) }) { child.insert(bounds: rect, item: item); return }
        entries.append((rect, item))
        if children.isEmpty && entries.count > capacity && maxDepth > 0 && bounds.width > 0 && bounds.height > 0 {
            let halfW = bounds.width / 2, halfH = bounds.height / 2
            children = (0..<4).map { i in QuadTree(bounds: Rect(x: bounds.x + Double(i % 2) * halfW, y: bounds.y + Double(i / 2) * halfH, width: halfW, height: halfH), capacity: capacity, maxDepth: maxDepth - 1) }
            let old = entries; entries = []
            for (r, value) in old {
                if let child = children.first(where: { $0.encloses(r) }) { child.insert(bounds: r, item: value) }
                else { entries.append((r, value)) }
            }
        }
    }
    private func encloses(_ r: Rect) -> Bool { bounds.left <= r.left && bounds.right >= r.right && bounds.top <= r.top && bounds.bottom >= r.bottom }
    public func query(_ area: Rect) -> [Value] { var result: [Value] = []; query(area, results: &result); return result }
    public func query(_ area: Rect, results: inout [Value]) {
        for (r, value) in entries where r.intersects(area) { results.append(value) }
        for child in children where child.bounds.intersects(area) { child.query(area, results: &results) }
    }
}

public final class ChannelGridCalculator {
    public struct ChannelGrid: Equatable, Sendable {
        public var xChannels: [Int]
        public var yChannels: [Int]
        public init(xChannels: [Int] = [], yChannels: [Int] = []) { self.xChannels = xChannels; self.yChannels = yChannels }
    }
    private var grids: [LayoutNode: ChannelGrid] = [:]
    public init() {}
    public func buildChannels(_ root: LayoutNode) {
        grids = [:]
        var stack = [root], visited = Set<LayoutNode>()
        while let node = stack.popLast() {
            guard visited.insert(node).inserted else { continue }
            var xs = Set<Int>(), ys = Set<Int>()
            if !node.children.isEmpty {
                for n in [node] + node.children {
                    xs.formUnion([Int(n.x), Int(n.bounds.right)]); ys.formUnion([Int(n.y), Int(n.bounds.bottom)])
                }
                func cuts(_ nodes: [LayoutNode], horizontal: Bool) -> [Int] {
                    let sorted = nodes.sorted { horizontal ? $0.x < $1.x : $0.y < $1.y }
                    var end = -Double.infinity, result: [Int] = []
                    for n in sorted {
                        let start = horizontal ? n.x : n.y
                        if start > end && end.isFinite { result.append(Int((start + end) / 2)) }
                        end = max(end, horizontal ? n.bounds.right : n.bounds.bottom)
                    }
                    return result
                }
                xs.formUnion(cuts(node.children, horizontal: true)); ys.formUnion(cuts(node.children, horizontal: false))
            }
            grids[node] = ChannelGrid(xChannels: xs.sorted(), yChannels: ys.sorted()); stack.append(contentsOf: node.children)
        }
    }
    public func getGrid(_ node: LayoutNode) -> ChannelGrid { grids[node] ?? ChannelGrid() }
}

public final class BspTreeNode {
    public enum Axis: Sendable { case none, horizontal, vertical }
    public var bounds: Rect
    public var splitAxis: Axis = .none
    public var splitPosition: Double = 0
    public var left: BspTreeNode?
    public var right: BspTreeNode?
    public var containedNodes: [LayoutNode] = []
    public var isLeaf: Bool { left == nil && right == nil }
    public init(bounds: Rect) { self.bounds = bounds }
}

/// Binary partitions use whitespace cuts, never cuts through child rectangles.
public final class BspGridCalculator {
    private var trees: [LayoutNode: BspTreeNode] = [:]
    private var graph: LayoutGraph?
    public init() {}
    public func buildTree(_ graph: LayoutGraph) {
        self.graph = graph; trees = [:]
        var stack = [graph.root], visited = Set<LayoutNode>()
        while let node = stack.popLast() {
            guard visited.insert(node).inserted else { continue }
            var effective = node, wrappers = Set<LayoutNode>()
            while effective.children.count == 1 && wrappers.insert(effective).inserted { effective = effective.children[0] }
            if effective.children.count > 1 {
                let bounds = node === graph.root ? enclosingBounds(effective.children).inflated(by: 20) : node.bounds.union(enclosingBounds(effective.children))
                trees[node] = build(bounds, nodes: effective.children, axis: .vertical, depth: 0)
            }
            stack.append(contentsOf: node.children)
        }
    }
    private func build(_ bounds: Rect, nodes: [LayoutNode], axis: BspTreeNode.Axis, depth: Int) -> BspTreeNode {
        let tree = BspTreeNode(bounds: bounds); tree.containedNodes = nodes
        guard nodes.count > 1, depth < 64 else { return tree }
        for attempt in [axis, axis == .vertical ? .horizontal : .vertical] {
            let vertical = attempt == .vertical
            let sorted = nodes.sorted { vertical ? $0.x < $1.x : $0.y < $1.y }
            var end = vertical ? sorted[0].bounds.right : sorted[0].bounds.bottom
            var cuts: [(Int, Double)] = []
            for i in 1..<sorted.count {
                let start = vertical ? sorted[i].x : sorted[i].y
                if start > end { cuts.append((i, (start + end) / 2)) }
                end = max(end, vertical ? sorted[i].bounds.right : sorted[i].bounds.bottom)
            }
            guard let cut = cuts.min(by: { abs($0.0 * 2 - sorted.count) < abs($1.0 * 2 - sorted.count) }) else { continue }
            tree.splitAxis = attempt; tree.splitPosition = cut.1
            let first = vertical ? Rect(x: bounds.x, y: bounds.y, width: cut.1 - bounds.x, height: bounds.height) : Rect(x: bounds.x, y: bounds.y, width: bounds.width, height: cut.1 - bounds.y)
            let second = vertical ? Rect(x: cut.1, y: bounds.y, width: bounds.right - cut.1, height: bounds.height) : Rect(x: bounds.x, y: cut.1, width: bounds.width, height: bounds.bottom - cut.1)
            let next: BspTreeNode.Axis = vertical ? .horizontal : .vertical
            tree.left = build(first, nodes: Array(sorted[..<cut.0]), axis: next, depth: depth + 1)
            tree.right = build(second, nodes: Array(sorted[cut.0...]), axis: next, depth: depth + 1)
            break
        }
        return tree
    }
    private func segments(_ tree: BspTreeNode?) -> [(start: Point, end: Point)] {
        guard let tree else { return [] }
        var stack = [tree], result: [(Point, Point)] = []
        let r = tree.bounds
        result += [(Point(x: r.left, y: r.top), Point(x: r.right, y: r.top)), (Point(x: r.left, y: r.bottom), Point(x: r.right, y: r.bottom)), (Point(x: r.left, y: r.top), Point(x: r.left, y: r.bottom)), (Point(x: r.right, y: r.top), Point(x: r.right, y: r.bottom))]
        while let n = stack.popLast() {
            if n.splitAxis == .vertical { result.append((Point(x: n.splitPosition, y: n.bounds.top), Point(x: n.splitPosition, y: n.bounds.bottom))) }
            if n.splitAxis == .horizontal { result.append((Point(x: n.bounds.left, y: n.splitPosition), Point(x: n.bounds.right, y: n.splitPosition))) }
            if let left = n.left { stack.append(left) }; if let right = n.right { stack.append(right) }
        }
        return result
    }
    public func getGlobalGridSegments() -> [(start: Point, end: Point)] { graph.map { segments(trees[$0.root]) } ?? [] }
    public func getLocalGridSegments(_ target: LayoutNode) -> [(start: Point, end: Point)] {
        var current: LayoutNode? = target, result: [(start: Point, end: Point)] = [], seen = Set<LayoutNode>()
        while let node = current, seen.insert(node).inserted { result += segments(trees[node]); current = node.parent }
        return result
    }
    private func grid(_ segments: [(start: Point, end: Point)]) -> ChannelGridCalculator.ChannelGrid {
        .init(xChannels: Array(Set(segments.filter { $0.start.x == $0.end.x }.map { Int($0.start.x) })).sorted(),
              yChannels: Array(Set(segments.filter { $0.start.y == $0.end.y }.map { Int($0.start.y) })).sorted())
    }
    public func getGlobalGrid() -> ChannelGridCalculator.ChannelGrid { grid(getGlobalGridSegments()) }
    public func getLocalGrid(_ target: LayoutNode) -> ChannelGridCalculator.ChannelGrid { grid(getLocalGridSegments(target)) }
    public func mergeGrids(_ first: ChannelGridCalculator.ChannelGrid, _ second: ChannelGridCalculator.ChannelGrid, _ third: ChannelGridCalculator.ChannelGrid? = nil) -> ChannelGridCalculator.ChannelGrid {
        .init(xChannels: Array(Set(first.xChannels + second.xChannels + (third?.xChannels ?? []))).sorted(),
              yChannels: Array(Set(first.yChannels + second.yChannels + (third?.yChannels ?? []))).sorted())
    }
}
