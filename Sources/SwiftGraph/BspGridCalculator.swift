import Foundation

/// Hierarchical whitespace partitions. Local cuts retain their bounded segment extents.
public final class BspGridCalculator {
    private var trees: [LayoutNode: BspTreeNode] = [:]
    private var graph: LayoutGraph?
    public init() {}
    public func buildTree(_ graph: LayoutGraph) {
        self.graph = graph; trees = [:]
        var stack = [graph.root], visited = Set<LayoutNode>()
        while let node = stack.popLast() {
            guard visited.insert(node).inserted else { continue }
            var source = node, wrappers = Set<LayoutNode>()
            while source.children.count == 1 && wrappers.insert(source).inserted { source = source.children[0] }
            if source.children.count > 1 {
                let bounds = effectiveBounds(node, children: source.children, source: source)
                trees[node] = build(bounds, nodes: source.children, axis: .vertical)
            }
            stack.append(contentsOf: node.children.reversed())
        }
    }
    private func effectiveBounds(_ parent: LayoutNode, children: [LayoutNode], source: LayoutNode) -> Rect {
        if let owner = parent.parent, let tree = trees[owner], let leaf = findLeaf(tree, target: parent) { return leaf.bounds }
        if parent === graph?.root { return enclosingBounds(children) }
        if source !== parent {
            var outermost = source, current = source.parent, seen = Set<LayoutNode>()
            while let n = current, n !== parent.parent, seen.insert(n).inserted { outermost = n; current = n.parent }
            return outermost.bounds
        }
        var outermost = parent, current = parent.parent, seen = Set<LayoutNode>()
        while let n = current, n !== graph?.root, n.children.count == 1, seen.insert(n).inserted { outermost = n; current = n.parent }
        return outermost.bounds
    }
    private func build(_ bounds: Rect, nodes: [LayoutNode], axis: BspTreeNode.Axis) -> BspTreeNode {
        let tree = BspTreeNode(bounds: bounds); tree.containedNodes = nodes
        guard nodes.count > 1 else { return tree }
        for attempt in [axis, axis == .vertical ? .horizontal : .vertical] {
            let vertical = attempt == .vertical
            let sorted = nodes.sorted { vertical ? $0.x < $1.x : $0.y < $1.y }
            let center = vertical ? bounds.center.x : bounds.center.y
            // Cut through the widest gap, so the longest lane runs down the most open corridor; ties go to the centre.
            var maxEnd = -Double.infinity, split: Double?, widest = 0.0
            for i in 0..<(sorted.count - 1) {
                maxEnd = max(maxEnd, vertical ? sorted[i].bounds.right : sorted[i].bounds.bottom)
                let nextStart = vertical ? sorted[i + 1].x : sorted[i + 1].y
                if nextStart > maxEnd {
                    let mid = (maxEnd + nextStart) / 2, gap = nextStart - maxEnd
                    if split == nil || gap > widest + 1e-9 || (abs(gap - widest) <= 1e-9 && abs(mid - center) < abs(split! - center)) { split = mid; widest = gap }
                }
            }
            guard let cut = split else { continue }
            let left = nodes.filter { (vertical ? $0.center.x : $0.center.y) < cut }
            let right = nodes.filter { (vertical ? $0.center.x : $0.center.y) >= cut }
            guard !left.isEmpty && !right.isEmpty else { continue }
            tree.splitAxis = attempt; tree.splitPosition = cut
            let first = vertical ? Rect(x: bounds.x, y: bounds.y, width: cut - bounds.x, height: bounds.height) : Rect(x: bounds.x, y: bounds.y, width: bounds.width, height: cut - bounds.y)
            let second = vertical ? Rect(x: cut, y: bounds.y, width: bounds.right - cut, height: bounds.height) : Rect(x: bounds.x, y: cut, width: bounds.width, height: bounds.bottom - cut)
            let next: BspTreeNode.Axis = vertical ? .horizontal : .vertical
            tree.left = build(first, nodes: left, axis: next); tree.right = build(second, nodes: right, axis: next)
            break
        }
        return tree
    }
    private func findLeaf(_ tree: BspTreeNode?, target: LayoutNode) -> BspTreeNode? {
        guard let tree, tree.containedNodes.contains(target) else { return nil }
        if tree.isLeaf { return tree }
        return findLeaf(tree.left, target: target) ?? findLeaf(tree.right, target: target)
    }
    private func segment(_ node: BspTreeNode) -> (start: Point, end: Point)? {
        if node.splitAxis == .horizontal { return (Point(x: node.bounds.left, y: node.splitPosition), Point(x: node.bounds.right, y: node.splitPosition)) }
        if node.splitAxis == .vertical { return (Point(x: node.splitPosition, y: node.bounds.top), Point(x: node.splitPosition, y: node.bounds.bottom)) }
        return nil
    }
    private func divisions(_ tree: BspTreeNode?, depth: Int = 0) -> [(start: Point, end: Point)] {
        guard let tree, depth < 2 else { return [] }
        return (segment(tree).map { [$0] } ?? []) + divisions(tree.left, depth: depth + 1) + divisions(tree.right, depth: depth + 1)
    }
    public func getGlobalGridSegments() -> [(start: Point, end: Point)] {
        guard let graph, let tree = trees[graph.root] else { return [] }
        let r = tree.bounds
        return [(Point(x: r.left, y: r.top), Point(x: r.right, y: r.top)), (Point(x: r.left, y: r.bottom), Point(x: r.right, y: r.bottom)), (Point(x: r.left, y: r.top), Point(x: r.left, y: r.bottom)), (Point(x: r.right, y: r.top), Point(x: r.right, y: r.bottom))] + divisions(tree)
    }
    /// Every cut of every partition tree, plus the frame, in one deterministic list. Cuts keep the extent of their own
    /// partition, so they meet the cuts of the enclosing partition. Leaves holding several nodes that no straight cut
    /// separates get lanes `laneInset` outside each node's outline, split wherever they would cross another node.
    public func getAllGridSegments(laneInset: Double = 10) -> [(start: Point, end: Point)] {
        guard let graph, let root = trees[graph.root] else { return [] }
        let r = root.bounds
        var result = [(Point(x: r.left, y: r.top), Point(x: r.right, y: r.top)), (Point(x: r.left, y: r.bottom), Point(x: r.right, y: r.bottom)), (Point(x: r.left, y: r.top), Point(x: r.left, y: r.bottom)), (Point(x: r.right, y: r.top), Point(x: r.right, y: r.bottom))].map { (start: $0.0, end: $0.1) }
        var stack = [graph.root], visited = Set<LayoutNode>()
        while let node = stack.popLast() {
            guard visited.insert(node).inserted else { continue }
            if let tree = trees[node] { collect(tree, laneInset, &result) }
            stack.append(contentsOf: node.children.reversed())
        }
        return result
    }
    private func collect(_ tree: BspTreeNode, _ inset: Double, _ result: inout [(start: Point, end: Point)]) {
        if let s = segment(tree) { result.append(s) }
        if let left = tree.left { collect(left, inset, &result) }
        if let right = tree.right { collect(right, inset, &result) }
        guard tree.isLeaf, tree.containedNodes.count > 1, inset > 0 else { return }
        let b = tree.containedNodes.isEmpty ? tree.bounds : tree.bounds
        for horizontal in [true, false] {
            var lines = Set<Int>()
            for c in tree.containedNodes {
                for v in horizontal ? [c.bounds.top - inset, c.bounds.bottom + inset] : [c.bounds.left - inset, c.bounds.right + inset]
                where (horizontal ? v > b.top && v < b.bottom : v > b.left && v < b.right) && lines.insert(Int((v * 1000).rounded())).inserted {
                    // Walk the lane, skipping the span of every node it would cut through.
                    var from = horizontal ? b.left : b.top
                    let end = horizontal ? b.right : b.bottom
                    let cuts = tree.containedNodes.filter { horizontal ? $0.bounds.top < v && v < $0.bounds.bottom : $0.bounds.left < v && v < $0.bounds.right }
                        .map { horizontal ? ($0.bounds.left, $0.bounds.right) : ($0.bounds.top, $0.bounds.bottom) }.sorted { $0.0 < $1.0 }
                    func add(_ a: Double, _ z: Double) {
                        if z - a > 1e-6 { result.append(horizontal ? (Point(x: a, y: v), Point(x: z, y: v)) : (Point(x: v, y: a), Point(x: v, y: z))) }
                    }
                    for (lo, hi) in cuts { if lo > from { add(from, min(lo, end)) }; from = max(from, hi) }
                    if from < end { add(from, end) }
                }
            }
        }
    }
    private func pathDivisions(_ tree: BspTreeNode?, target: LayoutNode, expansion: Rect, original: Rect) -> [(start: Point, end: Point)] {
        guard let tree, tree.containedNodes.contains(target), tree.bounds.contains(target.center) else { return [] }
        var result: [(start: Point, end: Point)] = []
        if var s = segment(tree) {
            if tree.splitAxis == .horizontal {
                if abs(s.start.x - original.left) < 1 { s.start.x = expansion.left }
                if abs(s.end.x - original.right) < 1 { s.end.x = expansion.right }
            } else {
                if abs(s.start.y - original.top) < 1 { s.start.y = expansion.top }
                if abs(s.end.y - original.bottom) < 1 { s.end.y = expansion.bottom }
            }
            result.append(s)
        }
        if let left = tree.left, left.containedNodes.contains(target), left.bounds.contains(target.center) {
            result += pathDivisions(left, target: target, expansion: expansion, original: original)
        } else { result += pathDivisions(tree.right, target: target, expansion: expansion, original: original) }
        return result
    }
    public func getLocalGridSegments(_ target: LayoutNode) -> [(start: Point, end: Point)] {
        var current = target.parent, focus = target, seen = Set<LayoutNode>()
        var result: [(start: Point, end: Point)] = []
        while let n = current, seen.insert(n).inserted {
            if let tree = trees[n] {
                var expansionNode = n, wrappers = Set<LayoutNode>()
                while let parent = expansionNode.parent, parent.children.count == 1, wrappers.insert(parent).inserted { expansionNode = parent }
                let limit: Rect
                if let parent = expansionNode.parent, let outer = trees[parent] { limit = findLeaf(outer, target: expansionNode)?.bounds ?? expansionNode.bounds }
                else { limit = tree.bounds }
                result += pathDivisions(tree, target: focus, expansion: limit, original: tree.bounds)
            }
            focus = n; current = n.parent
        }
        return result
    }
    private func grid(_ segments: [(start: Point, end: Point)]) -> ChannelGridCalculator.ChannelGrid {
        .init(xChannels: segments.filter { $0.start.x == $0.end.x }.map { Int($0.start.x) },
              yChannels: segments.filter { $0.start.y == $0.end.y }.map { Int($0.start.y) })
    }
    public func getGlobalGrid() -> ChannelGridCalculator.ChannelGrid { guard let graph else { return .init() }; return grid(divisions(trees[graph.root])) }
    public func getLocalGrid(_ target: LayoutNode) -> ChannelGridCalculator.ChannelGrid {
        var result = grid(getLocalGridSegments(target)); result.xChannels.append(Int(target.center.x)); result.yChannels.append(Int(target.center.y)); return result
    }
    public func mergeGrids(_ first: ChannelGridCalculator.ChannelGrid, _ second: ChannelGridCalculator.ChannelGrid, _ third: ChannelGridCalculator.ChannelGrid? = nil) -> ChannelGridCalculator.ChannelGrid {
        .init(xChannels: Array(Set(first.xChannels + second.xChannels + (third?.xChannels ?? []))).sorted(), yChannels: Array(Set(first.yChannels + second.yChannels + (third?.yChannels ?? []))).sorted())
    }
}
