import Foundation

/// Node references are retained only on the caller and never passed to the executor.
struct TreePlacementPlan {
    var targets: [LayoutNode]
    var state: MetalPlacementState
}

func treePlacementPlan(
    _ graph: LayoutGraph,
    style: TreeLayoutStyle,
    configuration c: TreeLayoutConfiguration
) throws -> TreePlacementPlan {
    var targets = graph.nodes
    var ordered: [Int] = []
    var lists = Array(repeating: [Int](), count: targets.count)
    var records = Array(repeating: SIMD4<Int32>(0, -1, 0, 0), count: targets.count)
    var flags = targets.map {
        UInt32(($0.isGroup ? 1 : 0) | (($0.data as? String)?.lowercased() == "assistant" ? 2 : 0))
    }
    let index = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($0.element, $0.offset) })
    var mode: UInt32 = 0
    var scalars: [Float]
    if style == .treeMap {
        mode = 3
        scalars = [c.padding]
        var children = treeMapChildren(graph)
        var indices = index
        var seen = Set<LayoutNode>()
        var stack = [graph.root]
        while let node = stack.popLast() {
            try Task.checkCancellation()
            guard seen.insert(node).inserted else { continue }
            if indices[node] == nil {
                indices[node] = targets.count
                targets.append(node)
                lists.append([])
                records.append(SIMD4(0, -1, 0, 0))
                flags.append(node.isGroup ? 1 : 0)
            }
            let list = (children[node] ?? node.children).filter { !seen.contains($0) }
            children[node] = list
            ordered.append(indices[required: node])
            stack.append(contentsOf: list.reversed())
        }
        for node in seen { lists[indices[required: node]] = (children[node] ?? []).compactMap { indices[$0] } }
        if let root = indices[graph.root] { records[root].z = 1 }
    } else {
        let a = Adjacency(graph, excludingGroups: style == .balloon)
        let f = Forest(a, undirected: style == .balloon, degreeRoots: style == .balloon)
        let global = a.nodes.map { index[required: $0] }
        for i in a.nodes.indices {
            lists[global[i]] = f.children[i].map { global[$0] }
            records[global[i]].x = Int32(f.depth[i])
            for j in f.children[i] { records[global[j]].y = Int32(global[i]) }
        }
        if style == .balloon {
            mode = 1
            scalars = [c.minRadius]
            ordered = f.order.map { global[$0] }
            for (component, root) in f.roots.enumerated() {
                var stack = [root]
                while let i = stack.popLast() {
                    records[global[i]].z = Int32(component)
                    stack.append(contentsOf: f.children[i])
                }
            }
        } else {
            mode = style == .tree ? 0 : 2
            scalars = style == .tree ? [c.nodeSeparation, c.levelSeparation] : [c.layerDistance, c.siblingDistance]
            for root in f.roots {
                var stack = [(root, false)]
                while let (i, post) = stack.popLast() {
                    let regular =
                        style == .orgChart ? f.children[i].filter { flags[global[$0]] & 2 == 0 } : f.children[i]
                    if !post {
                        stack.append((i, true))
                        let hasAssistants = regular.count != f.children[i].count
                        for j in regular.reversed() {
                            if style == .orgChart {
                                records[global[j]].x = records[global[i]].x + (hasAssistants ? 2 : 1)
                            }
                            stack.append((j, false))
                        }
                    } else {
                        ordered.append(global[i])
                        if i == root { records[global[i]].z = 1 }
                    }
                }
                try Task.checkCancellation()
            }
            if style == .orgChart {
                for i in ordered { for j in lists[i] where flags[j] & 2 != 0 { flags[j] |= 8 } }
                var depths = Array(repeating: -1, count: targets.count)
                for i in ordered { depths[i] = Int(records[i].x) }
                scalars += orgChartLevelOffsets(targets, depths: depths, minimum: c.layerDistance)
            }
        }
    }
    for i in ordered { flags[i] |= 8 }
    var childOffsets: [UInt32] = [0]
    var children: [UInt32] = []
    for list in lists {
        children.append(contentsOf: list.map(UInt32.init))
        childOffsets.append(UInt32(children.count))
    }
    let size = Double(targets.map { max($0.width, $0.height) }.max() ?? 0)
    let magnitude: Double
    if style == .treeMap {
        magnitude = 4_000 + abs(Double(c.padding)) * Double(targets.count) * 4
    } else if style == .orgChart {
        let assistants = flags.filter { $0 & 10 == 10 }.count
        let horizontal =
            Double(targets.count) * (size + abs(Double(c.siblingDistance))) + Double(assistants) * (size + 20)
        let vertical = Double(scalars.dropFirst(2).map(abs).max() ?? 0) + Double(assistants) * (size + 30)
        magnitude = (max(horizontal, vertical) + size) * 4
    } else {
        magnitude = (size + Double(scalars.map(abs).max() ?? 0) + 1) * Double(max(1, targets.count)) * 4
    }
    var orientationSafe = true
    if style == .treeMap {
        // Precision analysis propagates dimensions only, never final positions.
        // GPU still computes subtree weights, rectangle sizes and coordinates.
        var weights = Array(repeating: Float(0.0), count: targets.count)
        var approximate = targets.map { SIMD2<Float>($0.width, $0.height) }
        for i in ordered.reversed() { weights[i] = max(1, lists[i].reduce(Float(0)) { $0 + weights[$1] }) }
        for i in ordered {
            if records[i].z == 1 { approximate[i] = SIMD2(1000, 1000) }
            let a = approximate[i]
            let floatVertical = a.x > a.y
            if lists[i].count > 1 {
                let nearBoundary = a.x != a.y && abs(a.x - a.y) <= max(a.x.ulp, a.y.ulp) * 8
                if nearBoundary { orientationSafe = false }
            }
            let fInner = SIMD2(max(0, a.x - 2 * c.padding), max(0, a.y - 2 * c.padding))
            let fTotal = max(1, lists[i].reduce(Float(0)) { $0 + weights[$1] })
            for child in lists[i] {
                let fRatio = weights[child] / fTotal
                approximate[child] =
                    floatVertical ? SIMD2(fInner.x * fRatio, fInner.y) : SIMD2(fInner.x, fInner.y * fRatio)
            }
        }
    }
    let state = MetalPlacementState(
        bounds: targets.map(\.bounds),
        flags: flags,
        records: records,
        order: ordered.map(UInt32.init),
        childOffsets: childOffsets,
        children: children,
        scalars: scalars,
        mode: mode,
        resource: "TreeLayouts",
        conservativeMagnitude: magnitude,
        serial: true,
        nodeCount: graph.nodes.count,
        discreteGeometrySafe: orientationSafe
    )
    return TreePlacementPlan(targets: targets, state: state)
}
