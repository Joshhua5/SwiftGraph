import Foundation

struct HierarchicalResult: Sendable {
    var bounds: [Rect]
    var paths: [[Point]]
    var metrics: LayoutExecutionMetrics
}

extension LayoutExecutor {
    func hierarchical(
        _ snapshot: GeometrySnapshot,
        configuration: HierarchicalLayoutConfiguration,
        transpose: Bool,
        backend: LayoutBackend
    ) async throws -> HierarchicalResult {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        try configuration.validate()
        try options.validate()
        let graph = snapshot.makeGraph()
        if transpose {
            for node in graph.nodes {
                let width = node.width
                node.width = node.height
                node.height = width
            }
        }
        var chosen = backend
        var reason: LayoutFallbackReason?
        var gpu: Double?
        var device: String?
        var metalWork = false
        if graph.nodes.isEmpty {
            chosen = .cpu
            reason = .noWork
        } else if backend == .automatic {
            if graph.nodes.count < options.minimumNodeCount {
                chosen = .cpu
                reason = .belowThreshold
            } else if !metalEnabled || !Self.isMetalAvailable {
                chosen = .cpu
                reason = .metalUnavailable
            } else {
                chosen = .metal
            }
        }
        if chosen == .metal {
            do {
                let plan = try LayoutStageScope.run("Plan", to: 0.1) {
                    try HierarchyPlacementPlan(graph, configuration: configuration)
                }
                try plan.validateMetal(tolerance: options.maximumCoordinateError)
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                let solver = try metalSolver()
                let result = try await LayoutStageScope.run("Ordering", from: 0.1, to: 0.6) {
                    try await solver.hierarchyAsync(plan, directed: false, retainBest: false)
                }
                metalWork = true
                gpu = result.gpuSeconds
                device = solver.deviceName
                try LayoutStageScope.run("Placement", from: 0.6) { try plan.apply(result, to: graph) }
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu
                reason = .precisionLimit
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu
                reason = .metalUnavailable
            }
        }
        if chosen == .cpu {
            let algorithm = HierarchicalLayoutAlgorithm()
            algorithm.layerSeparation = configuration.layerSeparation
            algorithm.nodeSeparation = configuration.nodeSeparation
            algorithm.maxNodesPerRank = configuration.maxNodesPerRank
            algorithm.routesEdges = configuration.routesEdges
            try algorithm.applyLayout(graph)
        }
        if transpose {
            for node in graph.nodes { node.bounds = Rect(x: node.y, y: node.x, width: node.height, height: node.width) }
            for edge in graph.edges { edge.path = edge.path.map { Point(x: $0.y, y: $0.x) } }
        }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).seconds
        var metrics = LayoutExecutionMetrics(
            requestedBackend: backend,
            backend: chosen,
            fallbackReason: reason,
            nodeCount: graph.nodes.count,
            iterations: graph.nodes.isEmpty ? 0 : 3,
            computeSeconds: elapsed,
            totalSeconds: elapsed,
            gpuSeconds: gpu,
            deviceName: device
        )
        metrics.cpuStages =
            chosen == .metal
            ? ["rank-construction", "virtual-edge-construction", "Double-geometry-reconstruction"]
            : ["hierarchy-layout"]
        metrics.metalStages = metalWork ? ["hierarchy-ordering", "weighted-isotonic-block-decisions"] : []
        return HierarchicalResult(bounds: graph.nodes.map(\.bounds), paths: graph.edges.map(\.path), metrics: metrics)
    }
}
