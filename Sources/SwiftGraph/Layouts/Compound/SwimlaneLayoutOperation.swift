import Foundation

/// Async composition on detached geometry, committed only after every child succeeds.
/// Cores must preserve topology and treat caller payloads/custom metadata as read-only.
public final class SwimlaneLayoutOperation: LayoutExecutionReporting {
    public private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []
    public var laneAssignment: [String: Int] = [:]
    public var laneWidth: Float = 200
    public var laneSpacing: Float = 20
    public var laneInternalPadding: Float = 20
    public var nodeVerticalSpacing: Float = 30
    public var subLayout: (any AsyncLayoutAlgorithm)?
    public private(set) var computedLanes: [(laneId: Int, x: Float, width: Float)] = []
    public let backend: LayoutBackend
    public let executor: LayoutExecutor

    public init(backend: LayoutBackend = .cpu, executor: LayoutExecutor = .shared) {
        self.backend = backend
        self.executor = executor
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastExecutionMetrics = []
        computedLanes = []
        try Task.checkCancellation()
        let transaction = try LayoutTransaction(graph)
        guard [laneWidth, laneSpacing, laneInternalPadding, nodeVerticalSpacing].allSatisfy(\.isFinite) else {
            throw LayoutExecutionError.invalidInput("Swimlane parameters must be finite.")
        }
        let operation = SwimlaneLayoutOperation(backend: backend, executor: executor)
        operation.laneAssignment = laneAssignment
        operation.laneWidth = laneWidth
        operation.laneSpacing = laneSpacing
        operation.laneInternalPadding = laneInternalPadding
        operation.nodeVerticalSpacing = nodeVerticalSpacing
        operation.subLayout = subLayout
        try await operation.applyWorking(transaction.working)
        try transaction.commit(to: graph)
        lastExecutionMetrics = operation.lastExecutionMetrics
        computedLanes = operation.computedLanes
    }

    private func applyWorking(_ graph: LayoutGraph) async throws {
        try Task.checkCancellation()
        computedLanes = []
        let computeStart = ContinuousClock.now
        let a = Adjacency(graph)
        let layers = a.layers()
        var rank = Array(repeating: 0, count: a.nodes.count)
        for (r, layer) in layers.enumerated() { for i in layer { rank[i] = r } }
        let targetLanes = max(1, Int(ceil(sqrt(Double(a.nodes.count)))))
        let ranksPerLane = max(1, Int(ceil(Double(layers.count) / Double(targetLanes))))
        var lanes: [Int: [LayoutNode]] = [:]
        for (i, n) in a.nodes.enumerated() {
            let lane = laneAssignment.isEmpty ? rank[i] / ranksPerLane : laneAssignment[n.id, default: 0]
            lanes[lane, default: []].append(n)
        }
        if backend != .cpu {
            let start = computeStart
            // Cores finish first; GPU then calculates lane widths and translations.
            if let subLayout {
                let ids = lanes.keys.sorted()
                for (index, id) in ids.enumerated() {
                    let g = subgraph(graph, nodes: lanes[required: id])
                    let coreStart = ContinuousClock.now
                    try await LayoutStageScope.run(
                        "Lane \(index + 1)/\(ids.count)",
                        from: 0.8 * Double(index) / Double(ids.count),
                        to: 0.8 * Double(index + 1) / Double(ids.count)
                    ) {
                        try await subLayout.applyLayoutAsync(g)
                    }
                    lastExecutionMetrics += compositionCoreRecords(
                        subLayout,
                        requested: backend,
                        graph: g,
                        start: coreStart
                    )
                }
            }
            let laneIds = lanes.keys.sorted()
            let nodeIndices = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element, $0.offset) })
            let members = laneIds.map { id in
                lanes[required: id]
                    .sorted {
                        rank[a.index[required: $0]] == rank[a.index[required: $1]]
                            ? a.index[required: $0] < a.index[required: $1]
                            : rank[a.index[required: $0]] < rank[a.index[required: $1]]
                    }
                    .map { nodeIndices[required: $0] }
            }
            let original = graph.nodes.map(\.bounds)
            let state = swimlanePlacementState(
                graph,
                members: members,
                ranks: rank,
                laneWidth: laneWidth,
                laneSpacing: laneSpacing,
                padding: laneInternalPadding,
                verticalSpacing: nodeVerticalSpacing,
                hasCore: subLayout != nil
            )
            let executor = self.executor
            let backend = self.backend
            var result = try await LayoutStageScope.run("Placement", from: subLayout == nil ? 0 : 0.8) {
                try await executor.placement(state, backend: backend)
            }
            if let placed = result.bounds {
                for (node, bounds) in zip(graph.nodes, placed) { node.bounds = bounds }
                for (lane, id) in laneIds.enumerated() {
                    let laneBounds = placed[graph.nodes.count + lane]
                    computedLanes.append((id, laneBounds.x, laneBounds.width))
                    if subLayout != nil, let first = members[lane].first {
                        let delta = Point(
                            x: placed[first].x - original[first].x,
                            y: placed[first].y - original[first].y
                        )
                        let selected = Set(members[lane])
                        for edge in graph.edges
                        where selected.contains(nodeIndices[edge.source] ?? -1)
                            && selected.contains(nodeIndices[edge.target] ?? -1)
                        {
                            edge.path = edge.path.map { $0 + delta }
                            edge.labelBounds = edge.labelBounds.translated(by: delta)
                        }
                    }
                }
                result.metrics.metalStages = [
                    subLayout == nil ? "lane widths, offsets and ranked placement" : "lane widths and core packing"
                ]
                result.metrics.cpuStages = ["layer and lane membership", "port selection"]
                if subLayout != nil { result.metrics.cpuStages.append("edge path translation") }
            } else {
                // Automatic fallback reuses the already-computed core geometry.
                placeLanesCPU(
                    graph,
                    adjacency: a,
                    layers: layers,
                    ranks: rank,
                    lanes: lanes,
                    coreAlreadyApplied: subLayout != nil
                )
                result.metrics.cpuStages = ["lane placement", "port selection"]
            }
            selectPorts(graph)
            result.metrics.computeSeconds = start.duration(to: .now).seconds
            result.metrics.totalSeconds = result.metrics.computeSeconds
            lastExecutionMetrics.append(result.metrics)
            return
        }
        let heights = layers.map { $0.map { a.nodes[$0].height }.max() ?? 0 }
        let ys = offsets(heights, gap: nodeVerticalSpacing)
        var x: Float = 0.0
        let ids = lanes.keys.sorted()
        for (index, id) in ids.enumerated() {
            try Task.checkCancellation()
            let nodes = lanes[required: id]
            let effectiveWidth: Float
            if let subLayout {
                let g = subgraph(graph, nodes: nodes)
                let coreStart = ContinuousClock.now
                try await LayoutStageScope.run("Lane \(index + 1)/\(ids.count)", part: index, of: ids.count) {
                    try await subLayout.applyLayoutAsync(g)
                }
                lastExecutionMetrics += compositionCoreRecords(
                    subLayout,
                    requested: backend,
                    graph: g,
                    start: coreStart
                )
                let b = g.bounds
                effectiveWidth = max(laneWidth, b.width + 2 * laneInternalPadding)
                translate(g, by: Point(x: x + effectiveWidth / 2 - b.center.x, y: laneInternalPadding - b.y))
            } else {
                effectiveWidth = max(laneWidth, (nodes.map(\.width).max() ?? 0) + 2 * laneInternalPadding)
                var bottom: Float = 0.0
                for n in nodes.sorted(by: {
                    rank[a.index[required: $0]] == rank[a.index[required: $1]]
                        ? a.index[required: $0] < a.index[required: $1]
                        : rank[a.index[required: $0]] < rank[a.index[required: $1]]
                }) {
                    n.y = max(bottom, ys[rank[a.index[required: n]]] + laneInternalPadding)
                    n.x = x + (effectiveWidth - n.width) / 2
                    bottom = n.bounds.bottom + nodeVerticalSpacing
                }
            }
            computedLanes.append((id, x, effectiveWidth))
            x += effectiveWidth + laneSpacing
        }
        selectPorts(graph)
    }

    private func placeLanesCPU(
        _ graph: LayoutGraph,
        adjacency a: Adjacency,
        layers: [[Int]],
        ranks rank: [Int],
        lanes: [Int: [LayoutNode]],
        coreAlreadyApplied: Bool
    ) {
        let heights = layers.map { $0.map { a.nodes[$0].height }.max() ?? 0 }
        let ys = offsets(heights, gap: nodeVerticalSpacing)
        var x: Float = 0.0
        for id in lanes.keys.sorted() {
            let nodes = lanes[required: id]
            let effectiveWidth: Float
            if coreAlreadyApplied {
                let g = subgraph(graph, nodes: nodes)
                let b = g.bounds
                effectiveWidth = max(laneWidth, b.width + 2 * laneInternalPadding)
                translate(g, by: Point(x: x + effectiveWidth / 2 - b.center.x, y: laneInternalPadding - b.y))
            } else {
                effectiveWidth = max(laneWidth, (nodes.map(\.width).max() ?? 0) + 2 * laneInternalPadding)
                var bottom: Float = 0.0
                for n in nodes.sorted(by: {
                    rank[a.index[required: $0]] == rank[a.index[required: $1]]
                        ? a.index[required: $0] < a.index[required: $1]
                        : rank[a.index[required: $0]] < rank[a.index[required: $1]]
                }) {
                    n.y = max(bottom, ys[rank[a.index[required: n]]] + laneInternalPadding)
                    n.x = x + (effectiveWidth - n.width) / 2
                    bottom = n.bounds.bottom + nodeVerticalSpacing
                }
            }
            computedLanes.append((id, x, effectiveWidth))
            x += effectiveWidth + laneSpacing
        }
    }

    private func selectPorts(_ graph: LayoutGraph) {
        for e in graph.edges where e.source !== e.target {
            if abs(e.source.center.y - e.target.center.y) < nodeVerticalSpacing / 2 {
                e.sourcePort = e.source.center.x < e.target.center.x ? .right : .left
                e.targetPort = e.sourcePort == .right ? .left : .right
            } else {
                e.sourcePort = e.source.center.y < e.target.center.y ? .bottom : .top
                e.targetPort = e.sourcePort == .bottom ? .top : .bottom
            }
        }
    }
}

/// Membership/order planning is CPU-only; widths, offsets and placement are GPU math.
private func swimlanePlacementState(
    _ graph: LayoutGraph,
    members: [[Int]],
    ranks: [Int],
    laneWidth: Float,
    laneSpacing: Float,
    padding: Float,
    verticalSpacing: Float,
    hasCore: Bool
) -> MetalPlacementState {
    let n = graph.nodes.count
    var bounds = graph.nodes.map(\.bounds)
    var records = Array(repeating: SIMD4<Int32>.zero, count: n + members.count)
    if hasCore {
        // Remove each core's arbitrary origin before Float conversion. GPU still
        // computes its envelope, effective lane width and final translation.
        for lane in members {
            guard let first = lane.first else { continue }
            let envelope = lane.dropFirst().reduce(bounds[first]) { $0.union(bounds[$1]) }
            for i in lane {
                bounds[i].x -= envelope.x
                bounds[i].y -= envelope.y
            }
        }
    }
    bounds.append(contentsOf: repeatElement(Rect(), count: members.count))
    var lists = Array(repeating: [Int](), count: bounds.count)
    for (i, rank) in ranks.enumerated() { records[i].x = Int32(rank) }
    for (lane, indices) in members.enumerated() { lists[n + lane] = indices }
    var offsets: [UInt32] = [0]
    var children: [UInt32] = []
    for list in lists {
        children.append(contentsOf: list.map(UInt32.init))
        offsets.append(UInt32(children.count))
    }
    let size = bounds.map { max($0.width, $0.height) }.max() ?? 0
    let extent = bounds.map { max(abs($0.x) + $0.width, abs($0.y) + $0.height) }.max() ?? 0
    let magnitude =
        max(
            (size + abs(verticalSpacing)) * Float(max(1, n)),
            (max(abs(laneWidth), (hasCore ? extent : size) + 2 * abs(padding)) + abs(laneSpacing))
                * Float(members.count)
        ) * 4 + abs(padding)
    return MetalPlacementState(
        bounds: bounds,
        flags: (0..<bounds.count).map { $0 < n ? 8 : 24 },
        records: records,
        order: members.indices.map { UInt32(n + $0) },
        childOffsets: offsets,
        children: children,
        scalars: [laneWidth, laneSpacing, padding, verticalSpacing, Float(n)],
        mode: hasCore ? 11 : 10,
        resource: "BasicLayouts",
        conservativeMagnitude: Double(magnitude),
        serial: true,
        nodeCount: n
    )
}
