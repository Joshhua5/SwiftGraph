import Foundation

/// Async composition on detached geometry, committed only after every child succeeds.
/// Cores must preserve topology and treat caller payloads/custom metadata as read-only.
public final class ComponentLayoutOperation: LayoutExecutionReporting {
    public private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []
    public var coreLayout: any AsyncLayoutAlgorithm
    public var componentSpacing: Float = 50
    public var preferredAspectRatio: Float = 1
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public init(_ coreLayout: any AsyncLayoutAlgorithm, backend: LayoutBackend = .cpu, executor: LayoutExecutor = .shared) {
        self.coreLayout = coreLayout; self.backend = backend; self.executor = executor
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastExecutionMetrics = []
        try Task.checkCancellation()
        let transaction = try LayoutTransaction(graph)
        let operation = ComponentLayoutOperation(coreLayout, backend: backend, executor: executor)
        operation.componentSpacing = componentSpacing
        operation.preferredAspectRatio = preferredAspectRatio
        try await operation.applyWorking(transaction.working)
        try transaction.commit(to: graph)
        lastExecutionMetrics = operation.lastExecutionMetrics
    }
    private func applyWorking(_ graph: LayoutGraph) async throws {
        try Task.checkCancellation()
        let a = Adjacency(graph), components = a.components()
        if components.count == 1 {
            let coreStart = ContinuousClock.now
            try await coreLayout.applyLayoutAsync(graph)
            lastExecutionMetrics += compositionCoreRecords(coreLayout, requested: backend, graph: graph, start: coreStart)
            return
        }
        var graphs: [LayoutGraph] = []
        for component in components {
            try Task.checkCancellation()
            let g = subgraph(graph, nodes: component.map { a.nodes[$0] })
            let coreStart = ContinuousClock.now
            try await coreLayout.applyLayoutAsync(g)
            lastExecutionMetrics += compositionCoreRecords(coreLayout, requested: backend, graph: g, start: coreStart)
            let b = g.bounds
            translate(g, by: Point(x: -b.x, y: -b.y)); graphs.append(g)
        }
        let packingStart = ContinuousClock.now
        let shifts = packedTranslations(graphs.map(\.bounds), spacing: componentSpacing, aspectRatio: preferredAspectRatio)
        for (g, shift) in zip(graphs, shifts) { translate(g, by: shift) }
        if backend != .cpu { lastExecutionMetrics.append(compositionCPURecord(backend, count: graph.nodes.count, start: packingStart, stages: ["component packing"])) }
    }
}

/// Async composition on detached geometry, committed only after every child succeeds.
/// Cores must preserve topology and treat caller payloads/custom metadata as read-only.
public final class MultiPageLayoutOperation: LayoutExecutionReporting {
    public private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []
    public var pageWidth: Float = 800
    public var pageHeight: Float = 1100
    public var pageSpacing: Float = 100
    public var coreLayout: any AsyncLayoutAlgorithm
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public init(_ coreLayout: (any AsyncLayoutAlgorithm)? = nil, backend: LayoutBackend = .cpu, executor: LayoutExecutor = .shared) {
        self.backend = backend; self.executor = executor
        if let coreLayout { self.coreLayout = coreLayout }
        else if backend == .cpu { self.coreLayout = HierarchicalLayoutAlgorithm() }
        else { self.coreLayout = HierarchicalLayoutOperation(backend: backend, executor: executor) }
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastExecutionMetrics = []
        try Task.checkCancellation()
        let transaction = try LayoutTransaction(graph)
        let operation = MultiPageLayoutOperation(coreLayout, backend: backend, executor: executor)
        operation.pageWidth = pageWidth
        operation.pageHeight = pageHeight
        operation.pageSpacing = pageSpacing
        try await operation.applyWorking(transaction.working)
        try transaction.commit(to: graph)
        lastExecutionMetrics = operation.lastExecutionMetrics
    }
    private func applyWorking(_ graph: LayoutGraph) async throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        for (i, component) in a.components().enumerated() {
            try Task.checkCancellation()
            let g = subgraph(graph, nodes: component.map { a.nodes[$0] })
            let coreStart = ContinuousClock.now
            try await coreLayout.applyLayoutAsync(g)
            lastExecutionMetrics += compositionCoreRecords(coreLayout, requested: backend, graph: g, start: coreStart)
            let packingStart = ContinuousClock.now
            let b = g.bounds
            translate(g, by: Point(x: Float(i % 3) * (pageWidth + pageSpacing) + (pageWidth - b.width) / 2 - b.x,
                                   y: Float(i / 3) * (pageHeight + pageSpacing) + (pageHeight - b.height) / 2 - b.y))
            if backend != .cpu { lastExecutionMetrics.append(compositionCPURecord(backend, count: g.nodes.count, start: packingStart, stages: ["page packing"])) }
        }
    }
}

/// Async composition on detached geometry, committed only after every child succeeds.
/// Cores must preserve topology and treat caller payloads/custom metadata as read-only.
public final class SubgraphLayoutOperation: LayoutExecutionReporting {
    public private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []
    public var selectedNodeIds: Set<String> = []
    public var coreLayout: any AsyncLayoutAlgorithm
    public var preserveCentroid = true
    /// Clearance takes precedence over centroid preservation. Disable for legacy placement.
    public var avoidUnselectedNodes = true
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public init(_ coreLayout: any AsyncLayoutAlgorithm, backend: LayoutBackend = .cpu, executor: LayoutExecutor = .shared) {
        self.coreLayout = coreLayout; self.backend = backend; self.executor = executor
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastExecutionMetrics = []
        try Task.checkCancellation()
        let transaction = try LayoutTransaction(graph)
        let operation = SubgraphLayoutOperation(coreLayout, backend: backend, executor: executor)
        operation.selectedNodeIds = selectedNodeIds
        operation.preserveCentroid = preserveCentroid
        operation.avoidUnselectedNodes = avoidUnselectedNodes
        try await operation.applyWorking(transaction.working)
        try transaction.commit(to: graph)
        lastExecutionMetrics = operation.lastExecutionMetrics
    }
    private func applyWorking(_ graph: LayoutGraph) async throws {
        try Task.checkCancellation()
        let g = subgraph(graph, nodes: graph.nodes.filter { selectedNodeIds.contains($0.id) })
        guard !g.nodes.isEmpty else { return }
        func centroid() -> Point { g.nodes.reduce(Point.zero) { $0 + $1.center } / Float(g.nodes.count) }
        let initial = centroid()
        let coreStart = ContinuousClock.now
        try await coreLayout.applyLayoutAsync(g)
        lastExecutionMetrics += compositionCoreRecords(coreLayout, requested: backend, graph: g, start: coreStart)
        let clearanceStart = ContinuousClock.now
        if preserveCentroid { translate(g, by: initial - centroid()) }
        if avoidUnselectedNodes {
            let obstacles = graph.nodes.filter { node in
                !selectedNodeIds.contains(node.id) && !g.nodes.contains {
                    isAncestor(node, of: $0) || isAncestor($0, of: node)
                }
            }.map(\.bounds) + graph.edges.filter {
                !selectedNodeIds.contains($0.source.id) && !selectedNodeIds.contains($0.target.id)
            }.flatMap { edge in
                // Moving the selection must not obstruct a route whose endpoints are untouched.
                zip(edge.path, edge.path.dropFirst()).map { a, b in
                    Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                }
            }
            var envelope = g.bounds
            for edge in g.edges {
                for p in edge.path { envelope = envelope.union(Rect(x: p.x, y: p.y)) }
                if edge.labelBounds.width > 0 { envelope = envelope.union(edge.labelBounds) }
            }
            let padded = obstacles.map { $0.inflated(by: 10) }
            if padded.contains(where: { $0.intersects(envelope) }) {
                let xs = Set([Float(0)] + padded.flatMap { [$0.left - envelope.right, $0.right - envelope.left] }).sorted()
                let ys = Set([Float(0)] + padded.flatMap { [$0.top - envelope.bottom, $0.bottom - envelope.top] }).sorted()
                var best: Point?
                for x in xs {
                    try Task.checkCancellation()
                    for y in ys {
                        let candidate = Point(x: x, y: y)
                        if let best, candidate.lengthSquared >= best.lengthSquared { continue }
                        if !padded.contains(where: { $0.intersects(envelope.translated(by: candidate)) }) { best = candidate }
                    }
                }
                if let best { translate(g, by: best) }
            }
        }
        if backend != .cpu { lastExecutionMetrics.append(compositionCPURecord(backend, count: graph.nodes.count, start: clearanceStart, stages: ["centroid preservation and selection clearance"])) }
        let routing = subgraph(graph, nodes: graph.nodes)
        routing.edges = graph.edges.filter { selectedNodeIds.contains($0.source.id) != selectedNodeIds.contains($0.target.id) }
        if backend == .cpu { ChannelEdgeRouter().routeEdges(routing) }
        else {
            let router = RoutingLayoutOperation(.channel, backend: backend, executor: executor)
            try await router.applyLayoutAsync(routing)
            lastExecutionMetrics += router.lastExecutionMetrics
        }
        if avoidUnselectedNodes {
            ObstaclePolyline.repair(graph, edges: graph.edges.filter {
                selectedNodeIds.contains($0.source.id) || selectedNodeIds.contains($0.target.id)
            })
        }
        try Task.checkCancellation()
    }
}

/// Async composition on detached geometry, committed only after every child succeeds.
/// Cores must preserve topology and treat caller payloads/custom metadata as read-only.
public final class RecursiveGroupLayoutOperation: LayoutExecutionReporting {
    public private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public var coreLayout: any AsyncLayoutAlgorithm
    public var groupPadding: Float = 20
    /// Refine framed placement using incoming boundary connections after fitting the frames.
    public var optimizeIncomingEdges: Bool = true
    var presetRouting: ((LayoutGraph) async throws -> (failures: [LayoutEdge], metrics: [LayoutExecutionMetrics]))?
    public var groupLayoutSelector: ((LayoutNode) -> any AsyncLayoutAlgorithm)?
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public init(_ coreLayout: any AsyncLayoutAlgorithm, backend: LayoutBackend = .cpu, executor: LayoutExecutor = .shared) {
        self.coreLayout = coreLayout; self.backend = backend; self.executor = executor
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastExecutionMetrics = []; unroutableEdges = []
        try Task.checkCancellation()
        let transaction = try LayoutTransaction(graph)
        let original = try GroupLayoutEngine(graph, padding: groupPadding)
        // Resolve against caller identities before suspending, then use only detached geometry.
        let layouts = original.groups.map { groupLayoutSelector?($0) ?? coreLayout }
        let refineIncoming = optimizeIncomingEdges
        let engine = try GroupLayoutEngine(transaction.working, padding: groupPadding)
        var records: [LayoutExecutionMetrics] = [], failures = Set<LayoutEdge>()
        for (group, layout) in zip(engine.groups, layouts) {
            try Task.checkCancellation()
            let projectionStart = ContinuousClock.now
            let projection = engine.projection(for: group)
            if backend != .cpu { records.append(compositionCPURecord(backend, count: projection.graph.nodes.count,
                start: projectionStart, stages: ["group edge projection"])) }
            if !group.children.isEmpty {
                let coreStart = ContinuousClock.now
                try await layout.applyLayoutAsync(projection.graph)
                records += compositionCoreRecords(layout, requested: backend, graph: projection.graph, start: coreStart)
                let placementStart = ContinuousClock.now
                try engine.accept(projection, in: group)
                if backend != .cpu { records.append(compositionCPURecord(backend, count: projection.graph.nodes.count,
                    start: placementStart, stages: ["frame overlap repair and rigid subtree placement"])) }
            }
            let routing = engine.routingGraph(for: group, allOwnedEdges: presetRouting != nil)
            if !routing.edges.isEmpty {
                if let presetRouting {
                    let result = try await presetRouting(routing)
                    failures.formUnion(result.failures); records += result.metrics
                } else if backend == .cpu {
                    let router = PolylineEdgeRouter(); router.routeEdges(routing)
                    failures.formUnion(router.unroutableEdges)
                } else {
                    let router = RoutingLayoutOperation(.polyline, backend: backend, executor: executor)
                    try await router.applyLayoutAsync(routing)
                    failures.formUnion(router.unroutableEdgeIndices.map { routing.edges[$0] })
                    records += router.lastExecutionMetrics
                }
            }
            let fitStart = ContinuousClock.now
            try engine.finish(group, routed: routing.edges)
            if backend != .cpu { records.append(compositionCPURecord(backend, count: group.children.count,
                start: fitStart, stages: ["group frame measurement and translation"])) }
        }
        if refineIncoming {
            let start = ContinuousClock.now
            try engine.refineIncomingEdges(excluding: failures)
            if backend != .cpu { records.append(compositionCPURecord(backend, count: transaction.working.nodes.count,
                start: start, stages: ["incoming group edge alignment and route validation"])) }
        }
        try transaction.commit(to: graph)
        lastExecutionMetrics = records
        unroutableEdges = zip(graph.edges, transaction.working.edges).compactMap { failures.contains($1) ? $0 : nil }
    }
}

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
    public init(backend: LayoutBackend = .cpu, executor: LayoutExecutor = .shared) { self.backend = backend; self.executor = executor }
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
        try Task.checkCancellation(); computedLanes = []
        let computeStart = ContinuousClock.now
        let a = Adjacency(graph), layers = a.layers()
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
                for id in lanes.keys.sorted() {
                    let g = subgraph(graph, nodes: lanes[id]!)
                    let coreStart = ContinuousClock.now
                    try await subLayout.applyLayoutAsync(g)
                    lastExecutionMetrics += compositionCoreRecords(subLayout, requested: backend, graph: g, start: coreStart)
                }
            }
            let laneIds = lanes.keys.sorted()
            let nodeIndices = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element, $0.offset) })
            let members = laneIds.map { id in lanes[id]!.sorted {
                rank[a.index[$0]!] == rank[a.index[$1]!] ? a.index[$0]! < a.index[$1]! : rank[a.index[$0]!] < rank[a.index[$1]!]
            }.map { nodeIndices[$0]! } }
            let original = graph.nodes.map(\.bounds)
            let state = swimlanePlacementState(graph, members: members, ranks: rank, laneWidth: laneWidth,
                laneSpacing: laneSpacing, padding: laneInternalPadding, verticalSpacing: nodeVerticalSpacing, hasCore: subLayout != nil)
            var result = try await executor.placement(state, backend: backend)
            if let placed = result.bounds {
                for (node, bounds) in zip(graph.nodes, placed) { node.bounds = bounds }
                for (lane, id) in laneIds.enumerated() {
                    let laneBounds = placed[graph.nodes.count + lane]
                    computedLanes.append((id, laneBounds.x, laneBounds.width))
                    if subLayout != nil, let first = members[lane].first {
                        let delta = Point(x: placed[first].x - original[first].x, y: placed[first].y - original[first].y)
                        let selected = Set(members[lane])
                        for edge in graph.edges where selected.contains(nodeIndices[edge.source] ?? -1) && selected.contains(nodeIndices[edge.target] ?? -1) {
                            edge.path = edge.path.map { $0 + delta }; edge.labelBounds = edge.labelBounds.translated(by: delta)
                        }
                    }
                }
                result.metrics.metalStages = [subLayout == nil ? "lane widths, offsets and ranked placement" : "lane widths and core packing"]
                result.metrics.cpuStages = ["layer and lane membership", "port selection"]
                if subLayout != nil { result.metrics.cpuStages.append("edge path translation") }
            } else {
                // Automatic fallback reuses the already-computed core geometry.
                placeLanesCPU(graph, adjacency: a, layers: layers, ranks: rank, lanes: lanes, coreAlreadyApplied: subLayout != nil)
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
        for id in lanes.keys.sorted() {
            try Task.checkCancellation()
            let nodes = lanes[id]!
            let effectiveWidth: Float
            if let subLayout {
                let g = subgraph(graph, nodes: nodes)
                let coreStart = ContinuousClock.now
                try await subLayout.applyLayoutAsync(g)
                lastExecutionMetrics += compositionCoreRecords(subLayout, requested: backend, graph: g, start: coreStart)
                let b = g.bounds; effectiveWidth = max(laneWidth, b.width + 2 * laneInternalPadding)
                translate(g, by: Point(x: x + effectiveWidth / 2 - b.center.x, y: laneInternalPadding - b.y))
            } else {
                effectiveWidth = max(laneWidth, (nodes.map(\.width).max() ?? 0) + 2 * laneInternalPadding)
                var bottom: Float = 0.0
                for n in nodes.sorted(by: { rank[a.index[$0]!] == rank[a.index[$1]!] ? a.index[$0]! < a.index[$1]! : rank[a.index[$0]!] < rank[a.index[$1]!] }) {
                    n.y = max(bottom, ys[rank[a.index[n]!]] + laneInternalPadding)
                    n.x = x + (effectiveWidth - n.width) / 2; bottom = n.bounds.bottom + nodeVerticalSpacing
                }
            }
            computedLanes.append((id, x, effectiveWidth)); x += effectiveWidth + laneSpacing
        }
        selectPorts(graph)
    }
    private func placeLanesCPU(_ graph: LayoutGraph, adjacency a: Adjacency, layers: [[Int]], ranks rank: [Int], lanes: [Int: [LayoutNode]], coreAlreadyApplied: Bool) {
        let heights = layers.map { $0.map { a.nodes[$0].height }.max() ?? 0 }, ys = offsets(heights, gap: nodeVerticalSpacing)
        var x: Float = 0.0
        for id in lanes.keys.sorted() {
            let nodes = lanes[id]!, effectiveWidth: Float
            if coreAlreadyApplied {
                let g = subgraph(graph, nodes: nodes), b = g.bounds
                effectiveWidth = max(laneWidth, b.width + 2 * laneInternalPadding)
                translate(g, by: Point(x: x + effectiveWidth / 2 - b.center.x, y: laneInternalPadding - b.y))
            } else {
                effectiveWidth = max(laneWidth, (nodes.map(\.width).max() ?? 0) + 2 * laneInternalPadding)
                var bottom: Float = 0.0
                for n in nodes.sorted(by: { rank[a.index[$0]!] == rank[a.index[$1]!] ? a.index[$0]! < a.index[$1]! : rank[a.index[$0]!] < rank[a.index[$1]!] }) {
                    n.y = max(bottom, ys[rank[a.index[n]!]] + laneInternalPadding)
                    n.x = x + (effectiveWidth - n.width) / 2; bottom = n.bounds.bottom + nodeVerticalSpacing
                }
            }
            computedLanes.append((id, x, effectiveWidth)); x += effectiveWidth + laneSpacing
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
private func swimlanePlacementState(_ graph: LayoutGraph, members: [[Int]], ranks: [Int], laneWidth: Float,
                                   laneSpacing: Float, padding: Float, verticalSpacing: Float, hasCore: Bool) -> MetalPlacementState {
    let n = graph.nodes.count
    var bounds = graph.nodes.map(\.bounds), records = Array(repeating: SIMD4<Int32>.zero, count: n + members.count)
    if hasCore {
        // Remove each core's arbitrary origin before Float conversion. GPU still
        // computes its envelope, effective lane width and final translation.
        for lane in members {
            guard let first = lane.first else { continue }
            let envelope = lane.dropFirst().reduce(bounds[first]) { $0.union(bounds[$1]) }
            for i in lane { bounds[i].x -= envelope.x; bounds[i].y -= envelope.y }
        }
    }
    bounds.append(contentsOf: repeatElement(Rect(), count: members.count))
    var lists = Array(repeating: [Int](), count: bounds.count)
    for (i, rank) in ranks.enumerated() { records[i].x = Int32(rank) }
    for (lane, indices) in members.enumerated() { lists[n + lane] = indices }
    var offsets: [UInt32] = [0], children: [UInt32] = []
    for list in lists { children.append(contentsOf: list.map(UInt32.init)); offsets.append(UInt32(children.count)) }
    let size = bounds.map { max($0.width, $0.height) }.max() ?? 0
    let extent = bounds.map { max(abs($0.x) + $0.width, abs($0.y) + $0.height) }.max() ?? 0
    let magnitude = max((size + abs(verticalSpacing)) * Float(max(1, n)),
                        (max(abs(laneWidth), (hasCore ? extent : size) + 2 * abs(padding)) + abs(laneSpacing)) * Float(members.count)) * 4 + abs(padding)
    return MetalPlacementState(bounds: bounds, flags: (0..<bounds.count).map { $0 < n ? 8 : 24 },
        records: records, order: members.indices.map { UInt32(n + $0) }, childOffsets: offsets, children: children,
        scalars: [laneWidth, laneSpacing, padding, verticalSpacing, Float(n)], mode: hasCore ? 11 : 10,
        resource: "BasicLayouts", conservativeMagnitude: Double(magnitude), serial: true, nodeCount: n)
}

private func compositionCPURecord(_ requested: LayoutBackend, count: Int, start: ContinuousClock.Instant, stages: [String]) -> LayoutExecutionMetrics {
    let seconds = start.duration(to: .now).seconds
    var metrics = LayoutExecutionMetrics(requestedBackend: requested, backend: .cpu, fallbackReason: nil,
        nodeCount: count, iterations: 1, computeSeconds: seconds, totalSeconds: seconds, gpuSeconds: nil, deviceName: nil)
    metrics.cpuStages = stages
    return metrics
}

/// Synchronous CPU adapters cannot report their own metrics. Preserve their work
/// in the composite record; arbitrary async cores should conform to reporting.
func compositionCoreRecords(_ core: any AsyncLayoutAlgorithm, requested: LayoutBackend,
                            graph: LayoutGraph, start: ContinuousClock.Instant) -> [LayoutExecutionMetrics] {
    if let reporting = core as? any LayoutExecutionReporting { return reporting.lastExecutionMetrics }
    guard core is any LayoutAlgorithm else { return [] }
    return [compositionCPURecord(requested, count: graph.nodes.count, start: start,
        stages: ["caller-supplied CPU core layout"])]
}
