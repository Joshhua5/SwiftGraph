import Foundation

public extension LayoutBuilder {
    /// Selects the backend for placement, analysis and routing stages in every preset.
    /// Composition ordering and exact geometry reconstruction remain CPU stages.
    @discardableResult func applyPattern(_ pattern: LayoutPatternType, backend: LayoutBackend,
                                        executor: LayoutExecutor = .shared) -> Self {
        switch pattern {
        case .standardOrganic: applyStandardOrganic(backend: backend, executor: executor)
        case .progressiveRefinement: applyProgressiveRefinement(backend: backend, executor: executor)
        case .hybridLayout: applyHybridLayout(backend: backend, executor: executor)
        case .networkTopology: applyNetworkTopology(backend: backend, executor: executor)
        case .socialNetwork: applySocialNetwork(backend: backend, executor: executor)
        case .largeGraphPreset: applyLargeGraphPreset(backend: backend, executor: executor)
        case .denseGraphPreset: applyDenseGraphPreset(backend: backend, executor: executor)
        case .mindMap: applyMindMap(backend: backend, executor: executor)
        case .standardHierarchical: applyStandardHierarchical(backend: backend, executor: executor)
        case .standardTree: applyStandardTree(backend: backend, executor: executor)
        case .standardCircular: applyStandardCircular(backend: backend, executor: executor)
        case .enterpriseArchitecture: applyEnterpriseArchitecture(backend: backend, executor: executor)
        case .callGraph: applyCallGraph(backend: backend, executor: executor)
        case .organizationChart: applyOrganizationChart(backend: backend, executor: executor)
        case .dataFlow: applyDataFlow(backend: backend, executor: executor)
        case .smallGraphPreset: applySmallGraphPreset(backend: backend, executor: executor)
        case .mediumGraphPreset: applyMediumGraphPreset(backend: backend, executor: executor)
        }
    }
    @discardableResult func applyStandardOrganic(backend: LayoutBackend, executor: LayoutExecutor = .shared, iterations: Int = 600, repulsionForce: Double = 100, attractionForce: Double = 0.05) -> Self {
        var configuration = OrganicLayoutConfiguration(); configuration.iterations = iterations; configuration.repulsionForce = repulsionForce; configuration.attractionForce = attractionForce
        let layout = OrganicLayoutOperation(backend: backend, executor: executor, configuration: configuration)
        return useAsyncAlgorithm(RecursiveGroupLayoutOperation(layout, backend: backend, executor: executor)).routePolyline(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applyProgressiveRefinement(backend: LayoutBackend, executor: LayoutExecutor = .shared, organicIterations: Int = 600, barycenterIterations: Int = 10) -> Self {
        useOrganic(backend: backend, executor: executor) { $0.iterations = organicIterations; $0.initialization = .current }.useBarycenter(backend: backend, executor: executor) { $0.iterations = barycenterIterations }.useRemoveOverlaps(backend: backend, executor: executor).routePolyline(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applyHybridLayout(backend: LayoutBackend, executor: LayoutExecutor = .shared, organicIterations: Int = 20) -> Self {
        useHierarchical(backend: backend, executor: executor).transform { graph in
            let a = Adjacency(graph)
            for i in a.nodes.indices { a.nodes[i].metadata[GraphMetadataKeys.layoutSubset] = a.neighbors[i].count <= 1 }
        }.useOrganic(backend: backend, executor: executor) { $0.iterations = organicIterations; $0.scope = .subset; $0.initialization = .current }.routePolyline(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applyWithEdgeBundling(backend: LayoutBackend, executor: LayoutExecutor = .shared, k: Double = 0.1) -> Self { routePolyline(backend: backend, executor: executor).routeWithBundling(backend: backend, executor: executor) { $0.k = k }.routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor) }
    @discardableResult func applyNetworkTopology(backend: LayoutBackend, executor: LayoutExecutor = .shared, hubCount: Int = 3, organicIterations: Int = 600) -> Self {
        analyzePageRank(backend: backend, executor: executor).transform { graph in
            let hubs = graph.nodes.enumerated().sorted { a, b in
                let left = a.element.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0
                let right = b.element.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0
                return left == right ? a.offset < b.offset : left > right
            }.prefix(max(0, hubCount)).map(\.element)
            for (i, hub) in hubs.enumerated() {
                hub.metadata[GraphMetadataKeys.fixed] = true
                let angle = 2 * Double.pi * Double(i) / Double(hubs.count)
                hub.center = Point(x: 300 * cos(angle), y: 300 * sin(angle))
            }
            let fixed = Set(hubs)
            for node in graph.nodes { node.metadata[GraphMetadataKeys.layoutSubset] = !fixed.contains(node) }
        }.useOrganic(backend: backend, executor: executor) { $0.scope = .subset; $0.iterations = organicIterations }.routeWithBundling(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applySocialNetwork(backend: LayoutBackend, executor: LayoutExecutor = .shared, organicIterations: Int = 600, repulsionForce: Double = 100) -> Self {
        analyzeClusters(backend: backend, executor: executor).useOrganic(backend: backend, executor: executor) { $0.iterations = organicIterations; $0.repulsionForce = repulsionForce }.routeWithBundling(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applyLargeGraphPreset(backend: LayoutBackend, executor: LayoutExecutor = .shared) -> Self { useOrganic(backend: backend, executor: executor).routePolyline(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor) }
    @discardableResult func applyDenseGraphPreset(backend: LayoutBackend, executor: LayoutExecutor = .shared) -> Self { useOrganic(backend: backend, executor: executor).routePolyline(backend: backend, executor: executor).routeWithBundling(backend: backend, executor: executor) { $0.k = 0.05 }.routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor) }
}

public extension LayoutBuilder {
    @discardableResult func applyStandardHierarchical(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        nodeSeparation: Double = 80, rankSeparation: Double = 120) -> Self {
        var configuration = HierarchicalLayoutConfiguration()
        configuration.nodeSeparation = nodeSeparation; configuration.layerSeparation = rankSeparation
        let core = HierarchicalLayoutOperation(backend: backend, executor: executor, configuration: configuration)
        return useAsyncAlgorithm(RecursiveGroupLayoutOperation(core, backend: backend, executor: executor))
            .separateEdges(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applyStandardTree(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        nodeSeparation: Double = 50, levelSeparation: Double = 50) -> Self {
        var configuration = TreeLayoutConfiguration()
        configuration.nodeSeparation = nodeSeparation; configuration.levelSeparation = levelSeparation
        let core = TreeLayoutOperation(style: .tree, backend: backend, executor: executor, configuration: configuration)
        return useAsyncAlgorithm(RecursiveGroupLayoutOperation(core, backend: backend, executor: executor))
            .routePolyline(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applyStandardCircular(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        radius: Double = 300) -> Self {
        var configuration = BasicLayoutConfiguration(); configuration.radius = radius
        let core = BasicLayoutOperation(style: .circular, backend: backend, executor: executor, configuration: configuration)
        return useAsyncAlgorithm(RecursiveGroupLayoutOperation(core, backend: backend, executor: executor))
            .routePolyline(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applyEnterpriseArchitecture(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        nodeSeparation: Double = 80, layerSeparation: Double = 120, componentSpacing: Double = 50) -> Self {
        var configuration = HierarchicalLayoutConfiguration()
        configuration.nodeSeparation = nodeSeparation; configuration.layerSeparation = layerSeparation
        let core = HierarchicalLayoutOperation(backend: backend, executor: executor, configuration: configuration)
        let components = ComponentLayoutOperation(core, backend: backend, executor: executor)
        components.componentSpacing = componentSpacing; components.preferredAspectRatio = 1.5
        return analyzePageRank(backend: backend, executor: executor)
            .useAsyncAlgorithm(RecursiveGroupLayoutOperation(components, backend: backend, executor: executor))
            .routeBsp(backend: backend, executor: executor)
            .routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applyCallGraph(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        nodeSeparation: Double = 60, layerSeparation: Double = 150) -> Self {
        useHierarchical(backend: backend, executor: executor) {
            $0.nodeSeparation = nodeSeparation; $0.layerSeparation = layerSeparation
        }.useRemoveOverlaps(backend: backend, executor: executor).separateEdges(backend: backend, executor: executor)
            .clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor).routeCurveFitting(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor)
    }
    @discardableResult func applyOrganizationChart(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        siblingDistance: Double = 40, layerDistance: Double = 80) -> Self {
        useOrgChart(backend: backend, executor: executor) {
            $0.siblingDistance = siblingDistance; $0.layerDistance = layerDistance
        }.routePolyline(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applyDataFlow(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        nodeSeparation: Double = 100, layerSeparation: Double = 150) -> Self {
        useHierarchical(backend: backend, executor: executor) {
            $0.nodeSeparation = nodeSeparation; $0.layerSeparation = layerSeparation
        }.routeChannel(backend: backend, executor: executor).separateEdges(backend: backend, executor: executor)
            .routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applySmallGraphPreset(backend: LayoutBackend, executor: LayoutExecutor = .shared) -> Self {
        useHierarchical(backend: backend, executor: executor) { $0.nodeSeparation = 80; $0.layerSeparation = 120 }
            .useRemoveOverlaps(backend: backend, executor: executor).separateEdges(backend: backend, executor: executor)
            .clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor).routeCurveFitting(backend: backend, executor: executor) { $0.iterations = 3 }
            .routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor)
    }
    @discardableResult func applyMediumGraphPreset(backend: LayoutBackend, executor: LayoutExecutor = .shared) -> Self {
        useHierarchical(backend: backend, executor: executor) { $0.nodeSeparation = 60; $0.layerSeparation = 100 }
            .separateEdges(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applyWithSmoothCurves(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        curveFittingIterations: Int = 3) -> Self {
        routePolyline(backend: backend, executor: executor)
            .clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor).routeCurveFitting(backend: backend, executor: executor) { $0.iterations = curveFittingIterations }
            .routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor)
    }
    @discardableResult func applyWithBspRouting(backend: LayoutBackend, executor: LayoutExecutor = .shared) -> Self {
        routeBsp(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applyGrainSwimlane(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        laneAssignment: [String: Int], laneWidth: Double = 200, laneSpacing: Double = 20,
        laneInternalPadding: Double = 20, nodeVerticalSpacing: Double = 40) -> Self {
        useSwimlane(backend: backend, executor: executor) {
            $0.laneAssignment = laneAssignment; $0.laneWidth = laneWidth; $0.laneSpacing = laneSpacing
            $0.laneInternalPadding = laneInternalPadding; $0.nodeVerticalSpacing = nodeVerticalSpacing
        }.routeChannel(backend: backend, executor: executor).separateEdges(backend: backend, executor: executor)
            .clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor).routeCurveFitting(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor)
    }
}
