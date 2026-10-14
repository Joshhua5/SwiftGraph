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
            [nodeSpacing, layerSpacing, componentSpacing, portSpacing, clearance, edgeSpacing].allSatisfy(\.isFinite),
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
        var geometryUsed = false
        if chosen == .metal {
            do {
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                if metal == nil { metal = try MetalForceSolver() }
                let solver = metal!
                diagnostics = try await DirectedLayoutOperation(configuration: configuration, cache: cache).applyAsyncWorking(graph,
                    // Placement is CPU work shared with the synchronous operation: the port-aware, layering and
                    // virtual-edge rules below have no GPU mirror, so only scoring uses the device.
                    hierarchy: { graph, hierarchy in try hierarchy.applyLayout(graph)
                    }, measure: { nodes, edges in
                        let result = try await solver.directedGeometryAsync(nodes: nodes, edges: edges, tolerance: self.options.maximumCoordinateError)
                        geometryUsed = geometryUsed || nodes.count > 1 || edges.count > 1
                        gpu += result.gpuSeconds
                        if geometryUsed { device = solver.deviceName }
                        // The kernel scores strict sharing; near-parallel proximity is reduced on the CPU.
                        var score = result.score
                        score.proximity = try DirectedGeometry.proximity(edges: edges, spacing: configuration.edgeSpacing)
                        return score
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
            totalSeconds: elapsed, gpuSeconds: geometryUsed ? gpu : nil, deviceName: device)
        let effectiveMode: DirectedLayoutMode = configuration.mode == .fresh && !configuration.fixedNodeIDs.isEmpty ? .incremental : configuration.mode
        metrics.cpuStages = graph.nodes.isEmpty ? [] : ["port-sizing-and-feedback-classification", "Double-geometry-reconstruction", "final-diagnostics"]
        if geometryUsed { metrics.cpuStages += ["exact-crossing-deduplication-and-score-reduction"] }
        if (diagnostics.stageMilliseconds["routing"] ?? 0) > 0 { metrics.cpuStages += ["obstacle-routing", "route-refinement"] }
        if (diagnostics.stageMilliseconds["placement"] ?? 0) > 0 {
            metrics.cpuStages += [effectiveMode == .fresh ? "hierarchy-placement" : "incremental-insertion"]
        }
        if effectiveMode == .fresh && !graph.nodes.isEmpty { metrics.cpuStages += ["component-connectivity", "component-packing"] }
        metrics.metalStages = geometryUsed ? ["directed-geometry-scoring"] : []
        return DirectedExecutionResult(bounds: graph.nodes.map(\.bounds), paths: graph.edges.map(\.path), diagnostics: diagnostics, metrics: metrics)
    }
}

// The async counterpart drives the same `DirectedComponentRun` steps as `apply`, letting the hierarchy
// and geometry kernels suspend without blocking the executor.
extension DirectedLayoutOperation {
    func applyAsyncWorking(_ original: LayoutGraph,
        hierarchy: (LayoutGraph, DirectedHierarchy) async throws -> Void,
        measure: ([LayoutNode], [LayoutEdge]) async throws -> DirectedGeometry.Score,
        isolation: isolated (any Actor)? = #isolation) async throws -> DirectedLayoutDiagnostics {
        if let constrained = constrainedConfiguration(for: original) {
            return try await DirectedLayoutOperation(configuration: constrained, cache: cache).applyAsyncWorking(original, hierarchy: hierarchy, measure: measure)
        }
        guard let plan = try prepare(original) else { return .init() }
        for component in plan.components {
            try Task.checkCancellation()
            let run = DirectedComponentRun(self, plan, component)
            for candidate in 0..<run.candidateCount {
                try Task.checkCancellation()
                if let placement = try run.place(candidate) { try await hierarchy(run.sub, placement) }
                run.placed()
                try run.routeIncumbent()
                let first = try await measure(run.members, run.edges)
                let score = try run.routeCoordinated(after: first) ? try await measure(run.members, run.edges) : first
                if run.settle(score) { break }
            }
            for candidate in run.refinementCandidates {
                try run.refine(candidate)
                run.keepRefined(try await measure(run.members, run.edges))
            }
            run.finishRefinement()
            try run.publish()
        }
        pack(plan)
        return try finish(plan, try await measure(plan.nodes, plan.edges))
    }
}
