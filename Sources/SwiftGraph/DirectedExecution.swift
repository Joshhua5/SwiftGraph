import Foundation

public final class DirectedLayoutAsyncOperation: LayoutExecutionReporting {
    public var configuration: DirectedLayoutConfiguration
    public var cache: DirectedLayoutCache?
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public private(set) var lastDiagnostics: DirectedLayoutDiagnostics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
    public init(backend: LayoutBackend, executor: LayoutExecutor = .shared,
                configuration: DirectedLayoutConfiguration = .init(), cache: DirectedLayoutCache? = nil) {
        self.backend = backend; self.executor = executor; self.configuration = configuration; self.cache = cache
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil; lastDiagnostics = nil
        let start = ContinuousClock.now, configuration = self.configuration
        try Task.checkCancellation(); try configuration.validateExecution()
        let transaction = try LayoutTransaction(graph)
        let snapshot = try DirectedExecutionSnapshot(transaction.working)
        let result = try await executor.directed(snapshot, configuration: configuration, cache: cache, backend: backend)
        for (node, bounds) in zip(transaction.working.nodes, result.bounds) { node.bounds = bounds }
        for (edge, path) in zip(transaction.working.edges, result.paths) { edge.path = path }
        try transaction.commit(to: graph)
        var metrics = result.metrics; metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics; lastDiagnostics = result.diagnostics
    }
}

public extension LayoutBuilder {
    @discardableResult func useDirected(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        cache: DirectedLayoutCache? = nil, configure: (inout DirectedLayoutConfiguration) -> Void = { _ in }) -> Self {
        var configuration = DirectedLayoutConfiguration(); configure(&configuration)
        return useAsyncAlgorithm(DirectedLayoutAsyncOperation(backend: backend, executor: executor, configuration: configuration, cache: cache))
    }
}

extension DirectedLayoutConfiguration {
    func validateExecution() throws {
        guard canvasAspectRatio.isFinite,
            [nodeSpacing, layerSpacing, componentSpacing, portSpacing, clearance].allSatisfy(\.isFinite),
            edgeWidths.allSatisfy(\.isFinite),
            previousBounds.values.allSatisfy({ [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width >= 0 && $0.height >= 0 }),
            insertionOrigins.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
            previousPaths.values.allSatisfy({ $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else {
            throw LayoutExecutionError.invalidInput("Directed configuration requires finite geometry.")
        }
    }
}

struct DirectedExecutionSnapshot: Sendable {
    struct Node: Sendable { var id: String; var bounds: Rect }
    struct Edge: Sendable { var source: Int; var target: Int; var sourcePort: PortConstraint; var targetPort: PortConstraint; var path: [Point] }
    var nodes: [Node]
    var edges: [Edge]
    init(_ graph: LayoutGraph) throws {
        let index = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element, $0.offset) })
        nodes = graph.nodes.map { Node(id: $0.id, bounds: $0.bounds) }
        edges = try graph.edges.map { edge in
            guard let source = index[edge.source], let target = index[edge.target] else {
                throw LayoutExecutionError.invalidInput("Directed edge endpoints must belong to the graph.")
            }
            return Edge(source: source, target: target, sourcePort: edge.sourcePort, targetPort: edge.targetPort, path: edge.path)
        }
    }
    func makeGraph() -> LayoutGraph {
        let graph = LayoutGraph()
        for state in nodes { let node = LayoutNode(id: state.id, width: state.bounds.width, height: state.bounds.height); node.bounds = state.bounds; graph.addNode(node) }
        for state in edges {
            let edge = LayoutEdge(source: graph.nodes[state.source], target: graph.nodes[state.target])
            edge.sourcePort = state.sourcePort; edge.targetPort = state.targetPort; edge.path = state.path; graph.addEdge(edge)
        }
        return graph
    }
}

struct DirectedExecutionResult: Sendable {
    var bounds: [Rect]; var paths: [[Point]]
    var diagnostics: DirectedLayoutDiagnostics; var metrics: LayoutExecutionMetrics
}

extension LayoutExecutor {
    func directed(_ snapshot: DirectedExecutionSnapshot, configuration: DirectedLayoutConfiguration,
                  cache: DirectedLayoutCache?, backend: LayoutBackend) async throws -> DirectedExecutionResult {
        let start = ContinuousClock.now
        try Task.checkCancellation(); try configuration.validateExecution(); try options.validate()
        var chosen = backend, reason: LayoutFallbackReason?, gpu = 0.0, device: String?
        let hasWork = snapshot.nodes.count > 1 || (configuration.mode == .fresh && !snapshot.nodes.isEmpty)
        if !hasWork { chosen = .cpu; reason = .noWork }
        else if backend == .automatic {
            if snapshot.nodes.count < options.minimumNodeCount { chosen = .cpu; reason = .belowThreshold }
            else if !metalEnabled || !Self.isMetalAvailable { chosen = .cpu; reason = .metalUnavailable }
            else { chosen = .metal }
        }
        var graph = snapshot.makeGraph(), diagnostics: DirectedLayoutDiagnostics
        var hierarchyUsed = false, geometryUsed = false
        if chosen == .metal {
            do {
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                if metal == nil { metal = try MetalForceSolver() }
                let solver = metal!
                diagnostics = try await DirectedLayoutOperation(configuration: configuration, cache: cache).applyAsyncWorking(graph,
                    hierarchy: { graph, hierarchy in
                        var settings = HierarchicalLayoutConfiguration()
                        settings.layerSeparation = hierarchy.layerSeparation; settings.nodeSeparation = hierarchy.nodeSeparation
                        settings.maxNodesPerRank = hierarchy.maxNodesPerRank
                        let plan = try HierarchyPlacementPlan(graph, configuration: settings)
                        try plan.validateMetal(tolerance: self.options.maximumCoordinateError)
                        let result = try await solver.hierarchyAsync(plan, directed: true, retainBest: hierarchy.retainBestSweep)
                        hierarchyUsed = true; gpu += result.gpuSeconds; device = solver.deviceName
                        try plan.apply(result, to: graph)
                    }, measure: { nodes, edges in
                        let result = try await solver.directedGeometryAsync(nodes: nodes, edges: edges, tolerance: self.options.maximumCoordinateError)
                        geometryUsed = geometryUsed || nodes.count > 1 || edges.count > 1
                        gpu += result.gpuSeconds
                        if geometryUsed { device = solver.deviceName }
                        return result.score
                    })
                device = solver.deviceName
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu; reason = .precisionLimit; graph = snapshot.makeGraph()
                diagnostics = try DirectedLayoutOperation(configuration: configuration, cache: cache).apply(graph)
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu; reason = .metalUnavailable; graph = snapshot.makeGraph()
                diagnostics = try DirectedLayoutOperation(configuration: configuration, cache: cache).apply(graph)
            }
        } else { diagnostics = try DirectedLayoutOperation(configuration: configuration, cache: cache).apply(graph) }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).seconds
        var metrics = LayoutExecutionMetrics(requestedBackend: backend, backend: chosen, fallbackReason: reason,
            nodeCount: snapshot.nodes.count, iterations: configuration.candidateCount, computeSeconds: elapsed,
            totalSeconds: elapsed, gpuSeconds: hierarchyUsed || geometryUsed ? gpu : nil, deviceName: device)
        let effectiveMode: DirectedLayoutMode = configuration.mode == .fresh && !configuration.fixedNodeIDs.isEmpty ? .incremental : configuration.mode
        metrics.cpuStages = graph.nodes.isEmpty ? [] : ["port-sizing-and-feedback-classification", "Double-geometry-reconstruction", "final-diagnostics"]
        if geometryUsed { metrics.cpuStages += ["exact-crossing-deduplication-and-score-reduction"] }
        if (diagnostics.stageMilliseconds["routing"] ?? 0) > 0 { metrics.cpuStages += ["obstacle-routing", "route-refinement"] }
        if (diagnostics.stageMilliseconds["placement"] ?? 0) > 0 {
            if hierarchyUsed { metrics.cpuStages += ["rank-and-virtual-edge-construction"] }
            else { metrics.cpuStages += [effectiveMode == .fresh ? "hierarchy-placement" : "incremental-insertion"] }
        }
        if effectiveMode == .fresh && !graph.nodes.isEmpty { metrics.cpuStages += ["component-connectivity", "component-packing"] }
        metrics.metalStages = (hierarchyUsed ? ["hierarchy-ordering", "weighted-isotonic-block-decisions"] : []) + (geometryUsed ? ["directed-geometry-scoring"] : [])
        return DirectedExecutionResult(bounds: graph.nodes.map(\.bounds), paths: graph.edges.map(\.path), diagnostics: diagnostics, metrics: metrics)
    }
}

// This async counterpart retains the synchronous candidate/routing pipeline while
// allowing hierarchy and geometry kernels to suspend without blocking the executor.
extension DirectedLayoutOperation {
    func applyAsyncWorking(_ original: LayoutGraph,
        hierarchy: (LayoutGraph, DirectedHierarchy) async throws -> Void,
        measure: ([LayoutNode], [LayoutEdge]) async throws -> DirectedGeometry.Score,
        isolation: isolated (any Actor)? = #isolation) async throws -> DirectedLayoutDiagnostics {
        if configuration.mode == .routesOnly && original.nodes.contains(where: { configuration.previousBounds[$0.id] == nil }) {
            var constrained = configuration
            for node in original.nodes where constrained.previousBounds[node.id] == nil { constrained.previousBounds[node.id] = node.bounds }
            return try await DirectedLayoutOperation(configuration: constrained, cache: cache).applyAsyncWorking(original, hierarchy: hierarchy, measure: measure)
        }
        if configuration.mode == .fresh && !configuration.fixedNodeIDs.isEmpty {
            var constrained = configuration
            constrained.mode = .incremental
            for node in original.nodes where constrained.fixedNodeIDs.contains(node.id) && constrained.previousBounds[node.id] == nil {
                constrained.previousBounds[node.id] = node.bounds
            }
            return try await DirectedLayoutOperation(configuration: constrained, cache: cache).applyAsyncWorking(original, hierarchy: hierarchy, measure: measure)
        }
        let start = ContinuousClock.now
        let graph = LayoutGraph()
        let nodes = original.nodes.map { LayoutNode(id: $0.id, width: $0.width, height: $0.height) }
        for (copy, source) in zip(nodes, original.nodes) { copy.bounds = source.bounds; graph.addNode(copy) }
        let byNode = Dictionary(uniqueKeysWithValues: original.nodes.enumerated().map { ($0.element, $0.offset) })
        for edge in original.edges {
            let copy = LayoutEdge(source: nodes[byNode[edge.source]!], target: nodes[byNode[edge.target]!])
            copy.sourcePort = edge.sourcePort; copy.targetPort = edge.targetPort
            graph.addEdge(copy)
        }
        guard !nodes.isEmpty else { return .init() }
        let allEdges = graph.edges
        let sizingStart = ContinuousClock.now
        let edgeIndex = Dictionary(uniqueKeysWithValues: allEdges.enumerated().map { ($0.element, $0.offset) })
        var feedback = Set(configuration.feedbackEdges.compactMap { allEdges.indices.contains($0) ? allEdges[$0] : nil })
        // Deterministic back-edge classification makes the ranking graph acyclic. It also
        // reserves the correct sides for reciprocal/cyclic links before measuring capacity.
        let outgoing = Dictionary(grouping: allEdges, by: \.source)
        var colors: [LayoutNode: Int] = [:]
        func visit(_ node: LayoutNode) throws {
            try Task.checkCancellation()
            colors[node] = 1
            let next = (outgoing[node] ?? []).sorted {
                $0.target.id == $1.target.id ? edgeIndex[$0]! < edgeIndex[$1]! : $0.target.id < $1.target.id
            }
            for edge in next where !feedback.contains(edge) && edge.source !== edge.target {
                if colors[edge.target] == 1 { feedback.insert(edge) }
                else if colors[edge.target] == nil { try visit(edge.target) }
            }
            colors[node] = 2
        }
        for node in nodes.sorted(by: { $0.id < $1.id }) where colors[node] == nil { try visit(node) }
        // Reserve capacity before ranking. Directional feedback has independent top ports.
        var sideCounts: [LayoutNode: [Int]] = [:]
        for edge in allEdges {
            if edge.source === edge.target || feedback.contains(edge) {
                sideCounts[edge.source, default: [0, 0, 0]][2] += 1
                sideCounts[edge.target, default: [0, 0, 0]][2] += 1
            } else {
                sideCounts[edge.source, default: [0, 0, 0]][1] += 1
                sideCounts[edge.target, default: [0, 0, 0]][0] += 1
            }
        }
        let widest = configuration.edgeWidths.max() ?? 1
        let pitch = max(configuration.portSpacing, widest * 2.5 + 6)
        for node in nodes {
            let c = sideCounts[node] ?? [0, 0, 0]
            let center = configuration.previousBounds[node.id]?.center ?? node.center
            node.height = max(node.height, Double(max(c[0], c[1]) - 1) * pitch + 24)
            node.width = max(node.width, Double(c[2] - 1) * pitch + 24)
            node.center = center
        }
        var diagnostics = DirectedLayoutDiagnostics()
        diagnostics.feedbackEdgeIndices = feedback.compactMap { edgeIndex[$0] }.sorted()
        let components = configuration.mode == .fresh ? Adjacency(graph).components() : [Array(nodes.indices)]
        let canonicalIndex = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element, $0.offset) })
        diagnostics.stageMilliseconds["sizing"] = milliseconds(sizingStart.duration(to: .now))
        var placementTime = 0.0, routingTime = 0.0
        var drawings: [(nodes: [LayoutNode], edges: [LayoutEdge], bounds: Rect)] = []
        for component in components {
            try Task.checkCancellation()
            let members = component.map { nodes[$0] }
            let memberSet = Set(members)
            let edges = allEdges.filter { memberSet.contains($0.source) }
            let sub = LayoutGraph()
            members.forEach(sub.addNodeDetached); sub.edges = edges
            let kept = members.filter { configuration.previousBounds[$0.id] != nil }
            let preserve = configuration.mode != .fresh && !kept.isEmpty
            let trialBudget = edges.count > 180 || members.count > 180 ? 2 : 5
            let trials = preserve ? 1 : max(1, min(trialBudget, configuration.candidateCount))
            var keyConfig = configuration
            // Geometry outside a component cannot influence a fresh component drawing.
            if configuration.mode == .fresh { keyConfig.previousBounds = [:]; keyConfig.insertionOrigins = [:] }
            let key = DirectedComponentKey(nodes: members.map { .init(id: $0.id, width: $0.width, height: $0.height) },
                edges: edges.map { .init(source: $0.source.id, target: $0.target.id, sourcePort: $0.sourcePort, targetPort: $0.targetPort, index: edgeIndex[$0]!) },
                configuration: keyConfig)
            var best = cache?.drawing(for: key)
            var legacyBest: DirectedComponentDrawing?
            let cached = best != nil
            if cached { diagnostics.cachedComponents += 1 }
            // The ordering score excludes ports and obstacles. On ordinary components,
            // also evaluate the terminal sweep so the final routed score breaks the tie.
            // Large components retain the two-candidate responsiveness bound.
            let variants = !preserve && trialBudget == 5 ? 2 : 1
            for candidate in 0..<(cached ? 0 : trials * variants) {
                let trial = candidate / variants
                try Task.checkCancellation()
                let placementStart = ContinuousClock.now
                if preserve {
                    placeIncrementally(members, edges: edges, pitch: pitch)
                } else {
                    sub.nodes = ordered(members, edges: edges, trial: trial)
                    sub.edges = edges.filter { !feedback.contains($0) && $0.source !== $0.target }
                    for n in members { let w = n.width; n.width = n.height; n.height = w }
                    let placement = DirectedHierarchy()
                    placement.retainBestSweep = candidate % variants == 0
                    placement.layerSeparation = max(configuration.layerSpacing, min(320, Double(edges.count) * 2.5))
                    placement.nodeSeparation = configuration.nodeSpacing
                    try await hierarchy(sub, placement)
                    for n in members { n.bounds = Rect(x: n.y, y: n.x, width: n.height, height: n.width) }
                    for e in sub.edges { e.path = e.path.map { Point(x: $0.y, y: $0.x) } }
                    // Break exact coordinate coincidences between unrelated ports deterministically.
                    for n in members { n.y += Double(canonicalIndex[n]! % 97) * 0.125 }
                    sub.edges = edges
                    widenCorridors(members, edges: edges, feedback: feedback)
                }
                placementTime += milliseconds(placementStart.duration(to: .now))
                let routingStart = ContinuousClock.now
                // Preserve the previous strategy as an incumbent for each ordering.
                // A more compact channel arrangement must earn its place using final
                // geometry, rather than discarding a lower-crossing drawing.
                let guides = edges.map(\.path)
                let router = DirectedRouter(nodes: members, edges: edges, feedback: feedback,
                                            edgeIndices: edgeIndex, configuration: configuration, pitch: pitch)
                try router.route(coordinated: false)
                let incumbent = DirectedComponentDrawing(bounds: members.map(\.bounds), paths: edges.map(\.path),
                    score: try await measure(members, edges))
                if configuration.mode == .fresh {
                    if legacyBest == nil || incumbent.score.precedes(legacyBest!.score) { legacyBest = incumbent }
                    for (edge, guide) in zip(edges, guides) { edge.path = guide }
                    try DirectedRouter(nodes: members, edges: edges, feedback: feedback,
                        edgeIndices: edgeIndex, configuration: configuration, pitch: pitch).route()
                }
                routingTime += milliseconds(routingStart.duration(to: .now))
                let score = try await measure(members, edges)
                let drawing = DirectedComponentDrawing(bounds: members.map(\.bounds), paths: edges.map(\.path), score: score)
                if best == nil || drawing.score.precedes(best!.score) { best = drawing }
                // Feedback paths seed port order in the next trial. Do not let the
                // compact trial alter the incumbent strategy's deterministic inputs.
                for (node, rect) in zip(members, incumbent.bounds) { node.bounds = rect }
                for (edge, path) in zip(edges, incumbent.paths) { edge.path = path }
                if score.crossings == 0 && score.shared == 0 && score.missing == 0 { break }
            }
            if !cached, configuration.mode == .fresh {
                // Refinement can change crossings: compare the two strategies only
                // after both receive the same final-geometry optimization.
                var refinedBest: DirectedComponentDrawing?
                let refinementStart = ContinuousClock.now
                for candidate in [legacyBest, best].compactMap({ $0 }) {
                    for (node, rect) in zip(members, candidate.bounds) { node.bounds = rect }
                    for (edge, path) in zip(edges, candidate.paths) { edge.path = path }
                    var refinement = DirectedRouter(nodes: members, edges: edges, feedback: feedback,
                        edgeIndices: edgeIndex, configuration: configuration, pitch: pitch)
                    try refinement.refine()
                    try DirectedDrawingCompaction.apply(nodes: members, edges: edges,
                        clearance: refinement.clearance, spacing: max(6, refinement.trackClearance + 2))
                    refinement = DirectedRouter(nodes: members, edges: edges, feedback: feedback,
                        edgeIndices: edgeIndex, configuration: configuration, pitch: pitch)
                    try refinement.refine()
                    try refinement.improveWorstRoutes()
                    let result = DirectedComponentDrawing(bounds: members.map(\.bounds), paths: edges.map(\.path),
                        score: try await measure(members, edges))
                    if refinedBest == nil || result.score.precedes(refinedBest!.score) { refinedBest = result }
                }
                best = refinedBest
                routingTime += milliseconds(refinementStart.duration(to: .now))
            }
            if let best {
                try Task.checkCancellation()
                for (node, rect) in zip(members, best.bounds) { node.bounds = rect }
                for (edge, path) in zip(edges, best.paths) { edge.path = path }
                if !cached {
                    let refined = DirectedComponentDrawing(bounds: members.map(\.bounds), paths: edges.map(\.path),
                        score: try await measure(members, edges))
                    cache?.insert(refined, for: key)
                }
            }
            drawings.append((members, edges, DirectedGeometry.bounds(nodes: members, edges: edges)))
        }
        diagnostics.stageMilliseconds["placement"] = placementTime
        diagnostics.stageMilliseconds["routing"] = routingTime
        if configuration.mode == .fresh { pack(&drawings) }
        // Restore input order; ranking candidates never affect identity or edge order.
        graph.nodes = nodes; graph.edges = allEdges
        let score = try await measure(nodes, allEdges)
        diagnostics.unroutableEdges = allEdges.indices.filter { allEdges[$0].path.count < 2 }
        diagnostics.crossings = score.crossings; diagnostics.sharedRuns = score.shared
        diagnostics.bends = score.bends; diagnostics.routeLength = score.length
        diagnostics.bounds = DirectedGeometry.bounds(nodes: nodes, edges: allEdges)
        for i in nodes.indices {
            if let prior = configuration.previousBounds[nodes[i].id] { diagnostics.displacement += (nodes[i].center - prior.center).length }
            for j in nodes.indices where j > i && nodes[i].bounds.intersects(nodes[j].bounds) {
                let pair = [nodes[i].id, nodes[j].id]
                diagnostics.overlappingNodeIDs.append(pair)
                if pair.contains(where: configuration.fixedNodeIDs.contains) { diagnostics.fixedNodeConflicts.append(pair) }
            }
        }
        try Task.checkCancellation()
        for (target, source) in zip(original.nodes, nodes) { target.bounds = source.bounds }
        for (target, source) in zip(original.edges, allEdges) { target.path = source.path }
        let elapsed = start.duration(to: .now).components
        diagnostics.stageMilliseconds["total"] = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        return diagnostics
    }

}
