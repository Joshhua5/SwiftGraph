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
        if let child = child(for: rect) { child.insert(bounds: rect, item: item); return }
        entries.append((rect, item))
        if children.isEmpty && entries.count > capacity && maxDepth > 0 && bounds.width > 0 && bounds.height > 0 {
            let halfW = bounds.width / 2, halfH = bounds.height / 2
            children = [(1.0, 0.0), (0.0, 0.0), (0.0, 1.0), (1.0, 1.0)].map { x, y in QuadTree(bounds: Rect(x: bounds.x + x * halfW, y: bounds.y + y * halfH, width: halfW, height: halfH), capacity: capacity, maxDepth: maxDepth - 1) }
            let old = entries; entries = []
            for (r, value) in old.reversed() {
                if let child = child(for: r) { child.insert(bounds: r, item: value) }
                else { entries.append((r, value)) }
            }
        }
    }
    private func encloses(_ r: Rect) -> Bool { bounds.left <= r.left && bounds.right >= r.right && bounds.top <= r.top && bounds.bottom >= r.bottom }
    private func child(for r: Rect) -> QuadTree<Value>? {
        guard !children.isEmpty else { return nil }
        let mid = bounds.center
        let top = r.y < mid.y && r.bottom < mid.y, bottom = r.y > mid.y
        let quadrant: Int
        if r.x < mid.x && r.right < mid.x { if top { quadrant = 1 } else if bottom { quadrant = 2 } else { return nil } }
        else if r.x > mid.x { if top { quadrant = 0 } else if bottom { quadrant = 3 } else { return nil } }
        else { return nil }
        return children[quadrant].encloses(r) ? children[quadrant] : nil
    }
    public func query(_ area: Rect) -> [Value] {
        var result: [Value] = [], stack = [self]
        while let node = stack.popLast() {
            for (r, value) in node.entries.reversed() where r.intersects(area) { result.append(value) }
            stack.append(contentsOf: node.children.filter { $0.bounds.intersects(area) })
        }
        return result
    }
    public func query(_ area: Rect, results: inout [Value]) {
        for (r, value) in entries.reversed() where r.intersects(area) { results.append(value) }
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

