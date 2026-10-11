import Foundation

/// A deterministic spanning forest, with iterative traversal for deep and cyclic input.
private struct Forest {
    var roots: [Int] = []
    var children: [[Int]]
    var depth: [Int]
    var order: [Int] = []
    init(_ a: Adjacency, undirected: Bool = false, degreeRoots: Bool = false) {
        children = Array(repeating: [], count: a.nodes.count); depth = Array(repeating: 0, count: a.nodes.count)
        var seen = Set<Int>()
        let candidates: [Int]
        if degreeRoots { candidates = a.nodes.indices.sorted { a.neighbors[$0].count == a.neighbors[$1].count ? $0 < $1 : a.neighbors[$0].count > a.neighbors[$1].count } }
        else { candidates = a.nodes.indices.filter { a.incoming[$0].isEmpty } + Array(a.nodes.indices) }
        for root in candidates where !seen.contains(root) {
            roots.append(root)
            var stack: [(Int, Int?)] = [(root, nil)]
            while let (i, parent) = stack.popLast() {
                guard seen.insert(i).inserted else { continue }
                if let parent { children[parent].append(i); depth[i] = depth[parent] + 1 }
                order.append(i)
                for j in (undirected ? a.neighbors[i] : a.outgoing[i]).reversed() where !seen.contains(j) { stack.append((j, i)) }
            }
        }
    }
}

public final class TreeLayoutAlgorithm: LayoutAlgorithm {
    public var nodeSeparation: Double = 50
    public var levelSeparation: Double = 50
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph), f = Forest(a)
        guard let maxDepth = f.depth.max() else { return }
        var heights = Array(repeating: 0.0, count: maxDepth + 1)
        for i in a.nodes.indices { heights[f.depth[i]] = max(heights[f.depth[i]], a.nodes[i].height) }
        let ys = offsets(heights, gap: levelSeparation)
        var cursor = 0.0
        for root in f.roots {
            var stack = [(root, false)]
            while let (i, post) = stack.popLast() {
                if !post { stack.append((i, true)); for j in f.children[i].reversed() { stack.append((j, false)) }; continue }
                let node = a.nodes[i]; node.y = ys[f.depth[i]]
                if let first = f.children[i].first, let last = f.children[i].last {
                    node.x = (a.nodes[first].center.x + a.nodes[last].center.x) / 2 - node.width / 2
                    cursor = max(cursor, node.bounds.right + nodeSeparation)
                } else { node.x = cursor; cursor += node.width + nodeSeparation }
            }
            cursor += nodeSeparation * 2
            try Task.checkCancellation()
        }
        straightEdges(graph)
    }
}

public final class RadialLayoutAlgorithm: LayoutAlgorithm {
    public var layerSeparation: Double = 100
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph, excludingGroups: true)
        guard let root = a.nodes.indices.max(by: { a.neighbors[$0].count == a.neighbors[$1].count ? $0 > $1 : a.neighbors[$0].count < a.neighbors[$1].count }) else { return }
        var depth = Array(repeating: -1, count: a.nodes.count), queue = [root], cursor = 0
        depth[root] = 0
        while cursor < queue.count {
            let i = queue[cursor]; cursor += 1
            for j in a.neighbors[i] where depth[j] < 0 { depth[j] = depth[i] + 1; queue.append(j) }
        }
        let outer = (depth.max() ?? 0) + 1
        for i in depth.indices where depth[i] < 0 { depth[i] = outer }
        a.nodes[root].center = .zero
        let span = a.nodes.map { hypot($0.width, $0.height) }.max()! + 20
        var previous = 0.0
        for d in 1...max(1, outer) {
            let ring = a.nodes.indices.filter { depth[$0] == d }
            guard !ring.isEmpty else { continue }
            let r = max(Double(d) * layerSeparation, max(Double(ring.count) * span / (2 * .pi), previous + layerSeparation))
            for (j, i) in ring.enumerated() {
                let angle = Double(j) * 2 * .pi / Double(ring.count)
                a.nodes[i].center = Point(x: r * cos(angle), y: r * sin(angle))
            }
            previous = r
        }
        straightEdges(graph)
    }
}

public final class RadialStarLayoutAlgorithm: LayoutAlgorithm {
    public var radius: Double = 200
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph, excludingGroups: true)
        guard let root = a.nodes.indices.max(by: { a.neighbors[$0].count == a.neighbors[$1].count ? $0 > $1 : a.neighbors[$0].count < a.neighbors[$1].count }) else { return }
        a.nodes[root].center = .zero
        let others = a.nodes.indices.filter { $0 != root }
        let span = a.nodes.map { hypot($0.width, $0.height) }.max() ?? 0
        let r = max(radius, Double(others.count) * (span + 20) / (2 * .pi))
        for (j, i) in others.enumerated() {
            let angle = Double(j) * 2 * .pi / Double(others.count)
            a.nodes[i].center = Point(x: r * cos(angle), y: r * sin(angle))
        }
        straightEdges(graph)
    }
}

public final class RadialTreeLayoutAlgorithm: LayoutAlgorithm {
    public var layerDistance: Double = 100
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph), f = Forest(a)
        var cursor = 0.0
        for root in f.roots {
            var component: [LayoutNode] = [], stack = [(root, 0.0, 2 * Double.pi)]
            while let (i, start, end) = stack.popLast() {
                let angle = (start + end) / 2, r = Double(f.depth[i]) * layerDistance
                a.nodes[i].center = Point(x: r * cos(angle), y: r * sin(angle)); component.append(a.nodes[i])
                let children = f.children[i], sweep = (end - start) / Double(max(1, children.count))
                for (j, child) in children.enumerated().reversed() { stack.append((child, start + Double(j) * sweep, start + Double(j + 1) * sweep)) }
            }
            let bounds = enclosingBounds(component)
            for node in component { node.x += cursor - bounds.x }
            cursor += bounds.width + layerDistance
            try Task.checkCancellation()
        }
        straightEdges(graph)
    }
}

public final class BalloonLayoutAlgorithm: LayoutAlgorithm {
    public var minRadius: Double = 50
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph, excludingGroups: true), f = Forest(a, undirected: true, degreeRoots: true)
        var sizes = Array(repeating: 1, count: a.nodes.count), cursor = 0.0
        for i in f.order.reversed() { sizes[i] += f.children[i].reduce(0) { $0 + sizes[$1] } }
        for (componentIndex, root) in f.roots.enumerated() {
            a.nodes[root].x = 0; a.nodes[root].y = 0
            var component = [a.nodes[root]], stack = [(root, 0.0, 2 * Double.pi)]
            while let (i, start, sweep) = stack.popLast() {
                let children = f.children[i]
                guard !children.isEmpty else { continue }
                let total = children.reduce(0) { $0 + sizes[$1] }
                let span = children.map { hypot(a.nodes[$0].width, a.nodes[$0].height) }.max()! + 20
                let r = max(minRadius, Double(children.count) * span / max(sweep, 1e-9))
                var angle = start
                for child in children {
                    let childSweep = sweep * Double(sizes[child]) / Double(total), mid = angle + childSweep / 2
                    a.nodes[child].center = a.nodes[i].center + Point(x: r * cos(mid), y: r * sin(mid))
                    component.append(a.nodes[child]); stack.append((child, angle, childSweep)); angle += childSweep
                }
            }
            let bounds = enclosingBounds(component)
            if componentIndex > 0 { for node in component { node.x += cursor - bounds.x } }
            cursor = componentIndex == 0 ? bounds.right + minRadius : cursor + bounds.width + minRadius
            try Task.checkCancellation()
        }
        straightEdges(graph)
    }
}

public final class OrgChartLayoutAlgorithm: LayoutAlgorithm {
    public var layerDistance: Double = 80
    public var siblingDistance: Double = 40
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph), f = Forest(a)
        let assistant = a.nodes.map { ($0.data as? String)?.lowercased() == "assistant" }
        var ys = Array(repeating: 0.0, count: a.nodes.count), cursor = 0.0
        for root in f.roots {
            var stack = [(root, false)]
            while let (i, post) = stack.popLast() {
                let regular = f.children[i].filter { !assistant[$0] }, assistants = f.children[i].filter { assistant[$0] }
                if !post {
                    stack.append((i, true))
                    for child in regular.reversed() { ys[child] = ys[i] + (assistants.isEmpty ? 1 : 2) * layerDistance; stack.append((child, false)) }
                    continue
                }
                let node = a.nodes[i]
                node.y = ys[i]
                if let first = regular.first, let last = regular.last { node.x = (a.nodes[first].center.x + a.nodes[last].center.x) / 2 - node.width / 2 }
                else { node.x = cursor; cursor += node.width }
                cursor = max(cursor, node.bounds.right)
                var assistantY = node.y + 20
                for j in assistants {
                    a.nodes[j].x = node.bounds.right + 20; a.nodes[j].y = assistantY
                    assistantY += a.nodes[j].height + 10; cursor = max(cursor, a.nodes[j].bounds.right)
                }
                cursor += siblingDistance
            }
            try Task.checkCancellation()
        }
        straightEdges(graph)
    }
}

public final class TreeMapLayoutAlgorithm: LayoutAlgorithm {
    public var padding: Double = 5
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        var children: [LayoutNode: [LayoutNode]] = [:], order: [LayoutNode] = [], seen = Set<LayoutNode>()
        if graph.root.children.count == graph.nodes.count && !graph.edges.isEmpty {
            let a = Adjacency(graph), f = Forest(a)
            children[graph.root] = f.roots.map { a.nodes[$0] }
            for i in a.nodes.indices { children[a.nodes[i]] = f.children[i].map { a.nodes[$0] } }
        }
        var stack = [graph.root]
        while let node = stack.popLast() {
            guard seen.insert(node).inserted else { continue }
            order.append(node)
            let list = (children[node] ?? node.children).filter { !seen.contains($0) }
            children[node] = list; stack.append(contentsOf: list.reversed())
        }
        var weights: [LayoutNode: Double] = [:]
        for node in order.reversed() { weights[node] = max(1, (children[node] ?? []).reduce(0.0) { $0 + weights[$1, default: 0] }) }
        graph.root.bounds = Rect(width: 1000, height: 1000)
        for node in order {
            try Task.checkCancellation()
            let r = node.bounds, vertical = r.width > r.height, list = children[node] ?? []
            let inner = Rect(x: r.x + padding, y: r.y + padding, width: max(0, r.width - 2 * padding), height: max(0, r.height - 2 * padding))
            var position = vertical ? inner.x : inner.y
            let total = max(1, list.reduce(0.0) { $0 + weights[$1, default: 1] })
            for child in list {
                let ratio = weights[child, default: 1] / total
                if vertical { child.bounds = Rect(x: position, y: inner.y, width: inner.width * ratio, height: inner.height); position += inner.width * ratio }
                else { child.bounds = Rect(x: inner.x, y: position, width: inner.width, height: inner.height * ratio); position += inner.height * ratio }
            }
        }
    }
}
