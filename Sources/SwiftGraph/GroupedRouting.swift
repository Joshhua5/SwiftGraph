import Foundation

/// Hierarchical channel carving, followed by safe node nudging and shared-segment bundling.
public final class OrthogonalGroupedEdgeRouter: EdgeRouter {
    public var bundleSpacing: Double = 4
    public var obstacleMargin: Double = 10
    public var bendPenalty: Double = 100
    /// Edges whose channel search used a direct center-to-center fallback.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    private let calculator = ChannelGridCalculator()
    public init() {}

    public func routeEdges(_ graph: LayoutGraph) {
        unroutableEdges = []
        guard !graph.edges.isEmpty else { return }
        if !graph.root.children.isEmpty { graph.root.bounds = enclosingBounds(graph.root.children) }
        calculator.buildChannels(graph.root)
        var paths: [LayoutEdge: [Point]] = [:]
        let edges = graph.edges.filter { $0.source !== $0.target }
        for edge in edges {
            if Task.isCancelled { return }
            let path = route(edge); edge.path = path; paths[edge] = path
        }
        nudge(graph, edges: edges, paths: &paths)
        if Task.isCancelled { return }
        bundle(edges, paths: paths)
        EdgeEndpointClipper.clipToNodeBounds(graph)
    }
    private func ancestors(_ node: LayoutNode) -> [LayoutNode] {
        var result: [LayoutNode] = [], seen = Set<LayoutNode>(), current: LayoutNode? = node
        while let n = current, seen.insert(n).inserted { result.append(n); current = n.parent }
        return result
    }
    private func lowerBound(_ list: [Int], _ value: Int) -> Int {
        var low = 0, high = list.count
        while low < high { let mid = (low + high) / 2; if list[mid] < value { low = mid + 1 } else { high = mid } }
        return low
    }
    private func route(_ edge: LayoutEdge) -> [Point] {
        let sx = Int(edge.source.center.x), sy = Int(edge.source.center.y), ex = Int(edge.target.center.x), ey = Int(edge.target.center.y)
        var xs: Set<Int> = [sx, ex], ys: Set<Int> = [sy, ey]
        let hierarchy = ancestors(edge.source) + ancestors(edge.target)
        for n in hierarchy {
            let grid = calculator.getGrid(n)
            xs.formUnion(grid.xChannels); ys.formUnion(grid.yChannels)
            xs.formUnion([Int(n.x), Int(n.bounds.right)]); ys.formUnion([Int(n.y), Int(n.bounds.bottom)])
        }
        let xGrid = xs.sorted(), yGrid = ys.sorted(), width = xs.count, height = ys.count
        var horizontal = RoutingBitSet(count: width * height), vertical = RoutingBitSet(count: width * height)
        for n in hierarchy {
            let grid = calculator.getGrid(n)
            let xStart = lowerBound(xGrid, Int(n.x)), xEnd = lowerBound(xGrid, Int(n.bounds.right))
            let yStart = lowerBound(yGrid, Int(n.y)), yEnd = lowerBound(yGrid, Int(n.bounds.bottom))
            for x in grid.xChannels {
                let ix = lowerBound(xGrid, x)
                let blocked = n.children.filter { $0.x < Double(x) && Double(x) < $0.bounds.right }.map { (lowerBound(yGrid, Int($0.y)), lowerBound(yGrid, Int($0.bounds.bottom))) }
                if yStart < yEnd { for y in yStart..<yEnd where !blocked.contains(where: { y >= $0.0 && y < $0.1 }) { vertical.insert(y * width + ix) } }
            }
            for y in grid.yChannels {
                let iy = lowerBound(yGrid, y)
                let blocked = n.children.filter { $0.y < Double(y) && Double(y) < $0.bounds.bottom }.map { (lowerBound(xGrid, Int($0.x)), lowerBound(xGrid, Int($0.bounds.right))) }
                if xStart < xEnd { for x in xStart..<xEnd where !blocked.contains(where: { x >= $0.0 && x < $0.1 }) { horizontal.insert(iy * width + x) } }
            }
        }
        for n in [edge.source, edge.target] {
            let xStart = lowerBound(xGrid, Int(n.x)), xEnd = lowerBound(xGrid, Int(n.bounds.right))
            let yStart = lowerBound(yGrid, Int(n.y)), yEnd = lowerBound(yGrid, Int(n.bounds.bottom))
            if xStart < xEnd && yStart < yEnd {
                for x in xStart..<xEnd { for y in yStart..<yEnd { horizontal.insert(y * width + x); vertical.insert(y * width + x) } }
            }
        }
        let start = (lowerBound(yGrid, sy) * width + lowerBound(xGrid, sx)) * 3
        let endX = lowerBound(xGrid, ex), endY = lowerBound(yGrid, ey)
        var queue = RoutingPriorityQueue<Int>(), costs = Array(repeating: Double.infinity, count: width * height * 3)
        var previous = Array(repeating: -1, count: costs.count), closed = RoutingBitSet(count: costs.count)
        queue.push(start, priority: 0); costs[start] = 0
        while let current = queue.pop() {
            if Task.isCancelled { return edge.path }
            if closed.contains(current) { continue }; closed.insert(current)
            let direction = current % 3, cell = current / 3, y = cell / width, x = cell % width
            if x == endX && y == endY {
                var i = current, path: [Point] = []
                while i != -1 { let c = i / 3; path.append(Point(x: Double(xGrid[c % width]), y: Double(yGrid[c / width]))); i = previous[i] }
                path.reverse(); return simplify(path)
            }
            for (dx, dy, dir) in [(-1, 0, 1), (1, 0, 1), (0, -1, 2), (0, 1, 2)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let passable = dy == 0 ? horizontal.contains(y * width + min(x, nx)) : vertical.contains(min(y, ny) * width + x)
                if !passable { continue }
                let next = (ny * width + nx) * 3 + dir
                let distance = abs(xGrid[nx] - xGrid[x]) + abs(yGrid[ny] - yGrid[y])
                let cost = costs[current] + Double(distance) + (direction != 0 && direction != dir ? bendPenalty : 0)
                if !closed.contains(next) && cost < costs[next] {
                    costs[next] = cost; previous[next] = current
                    queue.push(next, priority: cost + Double(abs(ex - xGrid[nx]) + abs(ey - yGrid[ny])))
                }
            }
        }
        if !unroutableEdges.contains(edge) { unroutableEdges.append(edge) }
        return [edge.source.center, edge.target.center]
    }
    private func simplify(_ points: [Point]) -> [Point] {
        guard points.count >= 3 else { return points }
        var result = [points[0]]
        for i in 1..<(points.count - 1) {
            let a = result.last!, b = points[i], c = points[i + 1]
            let sameX = abs(a.x - b.x) < 0.001 && abs(b.x - c.x) < 0.001
            let sameY = abs(a.y - b.y) < 0.001 && abs(b.y - c.y) < 0.001
            if !sameX && !sameY { result.append(b) }
        }
        result.append(points.last!); return result
    }
    private struct Segment: Hashable {
        var a: Point; var b: Point
        init(_ a: Point, _ b: Point) { if Self.reversed(a, b) { self.a = b; self.b = a } else { self.a = a; self.b = b } }
        static func reversed(_ a: Point, _ b: Point) -> Bool { a.x > b.x || (a.x == b.x && a.y > b.y) }
    }
    private func nudge(_ graph: LayoutGraph, edges: [LayoutEdge], paths: inout [LayoutEdge: [Point]]) {
        var counts: [Segment: Int] = [:], order: [Segment] = []
        for edge in edges {
            let path = paths[edge]!
            for (a, b) in zip(path, path.dropFirst()) {
                let s = Segment(a, b)
                if counts[s] == nil { order.append(s) }; counts[s, default: 0] += 1
            }
        }
        let tree = QuadTree<LayoutNode>(bounds: enclosingBounds(graph.nodes).inflated(by: 100))
        var stack = [graph.root], visited = Set<LayoutNode>(), moved = Set<LayoutNode>()
        while let n = stack.popLast() {
            if !visited.insert(n).inserted { continue }; tree.insert(bounds: n.bounds, item: n); stack.append(contentsOf: n.children.reversed())
        }
        for segment in order where counts[segment]! > 1 {
            let a = segment.a, b = segment.b, half = Double(counts[segment]!) * bundleSpacing / 2
            let vertical = abs(a.x - b.x) < 0.001
            let bus = vertical ? Rect(x: a.x - half - obstacleMargin, y: min(a.y, b.y), width: 2 * (half + obstacleMargin), height: abs(a.y - b.y)) : Rect(x: min(a.x, b.x), y: a.y - half - obstacleMargin, width: abs(a.x - b.x), height: 2 * (half + obstacleMargin))
            for node in tree.query(bus) {
                if node.isGroup || moved.contains(node) || node.bounds.contains(a) || node.bounds.contains(b) { continue }
                let shift: Point
                if vertical { shift = Point(x: node.center.x < a.x ? bus.left - node.bounds.right : bus.right - node.x, y: 0) }
                else { shift = Point(x: 0, y: node.center.y < a.y ? bus.top - node.bounds.bottom : bus.bottom - node.y) }
                let destination = node.bounds.translated(by: shift)
                if tree.query(destination).contains(where: { $0 !== node && !$0.isGroup && $0.bounds.intersects(destination) }) { continue }
                node.bounds = destination; moved.insert(node); tree.insert(bounds: node.bounds, item: node)
            }
        }
        for edge in edges where moved.contains(edge.source) || moved.contains(edge.target) {
            if Task.isCancelled { return }
            unroutableEdges.removeAll { $0 === edge }
            let path = route(edge); paths[edge] = path; edge.path = path
        }
    }
    private func bundle(_ edges: [LayoutEdge], paths: [LayoutEdge: [Point]]) {
        var segments: [Segment: [LayoutEdge]] = [:]
        for edge in edges { let path = paths[edge]!; for (a, b) in zip(path, path.dropFirst()) { segments[Segment(a, b), default: []].append(edge) } }
        for edge in edges {
            let path = paths[edge]!
            if path.count < 2 { continue }
            var lines: [(origin: Point, direction: Point)] = []
            for (a, b) in zip(path, path.dropFirst()) {
                let group = segments[Segment(a, b)]!, index = group.firstIndex(of: edge)!
                var offset = (Double(index) - Double(group.count - 1) / 2) * bundleSpacing
                if Segment.reversed(a, b) { offset = -offset }
                let d = b - a, len = d.length
                let p = len < 1e-9 ? a : a + Point(x: -d.y / len, y: d.x / len) * offset
                lines.append((p, d))
            }
            var final = [path[0]]
            for i in 0..<(lines.count - 1) {
                let a = lines[i], b = lines[i + 1]
                let determinant = a.direction.x * b.direction.y - b.direction.x * a.direction.y
                if abs(determinant) < 1e-9 { final.append(path[i + 1]) }
                else {
                    let delta = b.origin - a.origin
                    let t = (delta.x * b.direction.y - delta.y * b.direction.x) / determinant
                    final.append(a.origin + a.direction * t)
                }
            }
            final.append(path.last!); edge.path = final
        }
    }
}

struct RoutingBitSet {
    private var words: [UInt64]
    init(count: Int) { words = Array(repeating: 0, count: (count + 63) / 64) }
    mutating func insert(_ index: Int) { words[index >> 6] |= UInt64(1) << (index & 63) }
    func contains(_ index: Int) -> Bool { words[index >> 6] & (UInt64(1) << (index & 63)) != 0 }
}
