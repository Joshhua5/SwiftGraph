import Foundation

struct RadialResult: Sendable {
    var bounds: [Rect]
    var routeEdges: Bool
    var metrics: LayoutExecutionMetrics
}

/// Ring membership and angles are determined in Double on CPU. The GPU finds the
/// tightest pair for each node; those candidate pairs are re-evaluated on CPU.
struct RadialRing: Sendable {
    var indices: [Int]
    var angles: [Double]
    var diameters: [Float]
    var depth: Int

    var minimumChord: Double {
        guard angles.count > 1 else { return 2 }
        let sorted = angles.sorted()
        // The guard above leaves at least two angles.
        var result = 2 * abs(sin((sorted.last! - sorted.first!) / 2))
        for i in 1..<sorted.count { result = min(result, 2 * abs(sin((sorted[i] - sorted[i - 1]) / 2))) }
        return result
    }

    mutating func normalizeCollapsedAngles() {
        // The smallest circular gap is between sorted neighbors, including the
        // wraparound pair. This is the same collapse test as the CPU pair scan.
        if angles.count > 1 && minimumChord < 2e-12 {
            angles = angles.indices.map { Double($0) * 2 * .pi / Double(angles.count) }
        }
    }

    func clearance(_ i: Int, _ j: Int) -> Float {
        ((diameters[i] + diameters[j]) / 2 + 20) / Float(2 * abs(sin((angles[i] - angles[j]) / 2)))
    }

    func cpuClearance() throws -> Float {
        var radius: Float = 0.0
        for i in indices.indices {
            if i % 128 == 0 { try Task.checkCancellation() }
            for j in (i + 1)..<indices.count { radius = max(radius, clearance(i, j)) }
        }
        return radius
    }
}

struct RadialPlacementPlan {
    struct Component {
        var indices: [Int]
        var rings: Range<Int>
    }

    var rings: [RadialRing] = []
    var components: [Component] = []
    let style: RadialLayoutStyle

    var pairCount: Double {
        rings.reduce(0) { $0 + Double($1.indices.count) * Double(max(0, $1.indices.count - 1)) / 2 }
    }

    init(_ graph: LayoutGraph, style: RadialLayoutStyle) throws {
        self.style = style
        let a = Adjacency(graph, excludingGroups: style != .tree)
        let global = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element, $0.offset) })
        func append(_ indices: [Int], depth: [Int], angles: [Double]) {
            let firstRing = rings.count
            let byDepth = Dictionary(grouping: indices, by: { depth[$0] })
            for d in byDepth.keys.sorted() {
                let members = byDepth[required: d]
                var ring = RadialRing(
                    indices: members.map { global[required: a.nodes[$0]] },
                    angles: members.map { angles[$0] },
                    diameters: members.map { hypot(a.nodes[$0].width, a.nodes[$0].height) },
                    depth: d
                )
                ring.normalizeCollapsedAngles()
                rings.append(ring)
            }
            components.append(
                Component(indices: indices.map { global[required: a.nodes[$0]] }, rings: firstRing..<rings.count)
            )
        }
        if style == .tree {
            let forest = Forest(a)
            for root in forest.roots {
                try Task.checkCancellation()
                var indices: [Int] = []
                var angles = Array(repeating: 0.0, count: a.nodes.count)
                var stack = [(root, 0.0, 2 * Double.pi)]
                while let (i, start, end) = stack.popLast() {
                    angles[i] = (start + end) / 2
                    indices.append(i)
                    let children = forest.children[i]
                    let sweep = (end - start) / Double(max(1, children.count))
                    for (j, child) in children.enumerated().reversed() {
                        stack.append((child, start + Double(j) * sweep, start + Double(j + 1) * sweep))
                    }
                }
                append(indices, depth: forest.depth, angles: angles)
            }
        } else if let root = a.nodes.indices.max(by: {
            a.neighbors[$0].count == a.neighbors[$1].count ? $0 > $1 : a.neighbors[$0].count < a.neighbors[$1].count
        }) {
            var depth = Array(repeating: style == .star ? 1 : -1, count: a.nodes.count)
            depth[root] = 0
            if style == .radial {
                var queue = [root]
                var cursor = 0
                while cursor < queue.count {
                    if cursor % 128 == 0 { try Task.checkCancellation() }
                    let i = queue[cursor]
                    cursor += 1
                    for j in a.neighbors[i] where depth[j] < 0 {
                        depth[j] = depth[i] + 1
                        queue.append(j)
                    }
                }
                let outer = (depth.max() ?? 0) + 1
                for i in depth.indices where depth[i] < 0 { depth[i] = outer }
            }
            var angles = Array(repeating: 0.0, count: a.nodes.count)
            for (d, members) in Dictionary(grouping: Array(a.nodes.indices), by: { depth[$0] }) where d > 0 {
                for (j, i) in members.enumerated() { angles[i] = Double(j) * 2 * .pi / Double(members.count) }
            }
            append(Array(a.nodes.indices), depth: depth, angles: angles)
        }
    }

    func apply(_ clearances: [Float], to graph: LayoutGraph, spacing: Float) throws {
        for component in components {
            var previousRadius: Float = 0.0
            var previousHalf: Float = 0.0
            var placed: [Rect] = []
            for index in component.rings {
                try Task.checkCancellation()
                let ring = rings[index]
                let half = (ring.diameters.max() ?? 0) / 2
                let base =
                    ring.depth == 0
                    ? 0 : previousRadius + (style == .tree ? spacing : max(spacing, previousHalf + half + 20))
                var radius = max(base, clearances[index])
                if style == .tree {
                    radius = fittedRadialDepth(
                        ring.indices.map { graph.nodes[$0] },
                        angles: ring.angles,
                        previous: placed,
                        minimum: radius
                    )
                }
                for (i, node) in ring.indices.enumerated() {
                    graph.nodes[node].center = Point(
                        x: radius * Float(cos(ring.angles[i])),
                        y: radius * Float(sin(ring.angles[i]))
                    )
                }
                placed += ring.indices.map { graph.nodes[$0].bounds }
                previousRadius = radius
                previousHalf = half
            }
        }
        if style == .tree { packForest(graph.nodes, components: components.map(\.indices), spacing: max(20, spacing)) }
    }
}
