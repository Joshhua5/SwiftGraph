import Foundation

public final class ChannelGridCalculator {
    public struct ChannelGrid: Equatable, Sendable {
        public var xChannels: [Int]
        public var yChannels: [Int]

        public init(xChannels: [Int] = [], yChannels: [Int] = []) {
            self.xChannels = xChannels
            self.yChannels = yChannels
        }
    }

    private var grids: [LayoutNode: ChannelGrid] = [:]

    /// Clearance kept between a channel and the obstacle it runs beside: channels sit on child outlines inflated by up
    /// to this much (never past the midline of the gap) instead of on the outlines themselves. 0 keeps raw outlines.
    public var margin: Float = 0

    public init() {}

    public func buildChannels(_ root: LayoutNode) {
        grids = [:]
        var stack = [root]
        var visited = Set<LayoutNode>()
        while let node = stack.popLast() {
            guard visited.insert(node).inserted else { continue }
            var xs = Set<Int>()
            var ys = Set<Int>()
            if !node.children.isEmpty {
                if margin > 0 {
                    // Only the root's frame is a lane; a group's own border is not.
                    if node === root {
                        xs.formUnion([Int(node.x), Int(node.bounds.right)])
                        ys.formUnion([Int(node.y), Int(node.bounds.bottom)])
                    }
                    xs.formUnion(
                        outlines(node.children, within: node.bounds.left...node.bounds.right, horizontal: true)
                    )
                    ys.formUnion(
                        outlines(node.children, within: node.bounds.top...node.bounds.bottom, horizontal: false)
                    )
                } else {
                    for n in [node] + node.children {
                        xs.formUnion([Int(n.x), Int(n.bounds.right)])
                        ys.formUnion([Int(n.y), Int(n.bounds.bottom)])
                    }
                }
                func cuts(_ nodes: [LayoutNode], horizontal: Bool) -> [Int] {
                    let sorted = nodes.sorted { horizontal ? $0.x < $1.x : $0.y < $1.y }
                    var end = -Float.infinity
                    var result: [Int] = []
                    for n in sorted {
                        let start = horizontal ? n.x : n.y
                        if start > end && end.isFinite { result.append(Int((start + end) / 2)) }
                        end = max(end, horizontal ? n.bounds.right : n.bounds.bottom)
                    }
                    return result
                }
                xs.formUnion(cuts(node.children, horizontal: true))
                ys.formUnion(cuts(node.children, horizontal: false))
            }
            grids[node] = ChannelGrid(xChannels: xs.sorted(), yChannels: ys.sorted())
            stack.append(contentsOf: node.children)
        }
    }

    /// Each child's start and end lines pushed out by `margin`, but no further than halfway to the next obstacle beside
    /// it
    /// (one overlapping it across the axis) or the group edge. Left and top lines round down, right and bottom lines
    /// up,
    /// so a line never lands on the outline it was pushed away from.
    private func outlines(_ nodes: [LayoutNode], within range: ClosedRange<Float>, horizontal: Bool) -> [Int] {
        let rects = nodes.map(\.bounds)
        func span(_ r: Rect) -> (Float, Float) { horizontal ? (r.left, r.right) : (r.top, r.bottom) }
        func across(_ r: Rect) -> (Float, Float) { horizontal ? (r.top, r.bottom) : (r.left, r.right) }
        var result: [Int] = []
        for (i, rect) in rects.enumerated() {
            let (start, end) = span(rect)
            let (crossStart, crossEnd) = across(rect)
            var before = range.lowerBound
            var after = range.upperBound
            for (j, other) in rects.enumerated() where j != i {
                let (otherStart, otherEnd) = span(other)
                let (otherCrossStart, otherCrossEnd) = across(other)
                guard otherCrossStart < crossEnd && otherCrossEnd > crossStart else { continue }
                if otherEnd <= start { before = max(before, otherEnd) }
                if otherStart >= end { after = min(after, otherStart) }
            }
            result.append(Int((start - min(margin, max(0, start - before) / 2)).rounded(.down)))
            result.append(Int((end + min(margin, max(0, after - end) / 2)).rounded(.up)))
        }
        return result
    }

    public func getGrid(_ node: LayoutNode) -> ChannelGrid { grids[node] ?? ChannelGrid() }
}
