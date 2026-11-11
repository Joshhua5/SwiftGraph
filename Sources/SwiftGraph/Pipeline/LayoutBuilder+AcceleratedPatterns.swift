import Foundation

extension LayoutBuilder {
    /// Selects the backend for placement, analysis and routing stages in every preset.
    /// Composition ordering and exact geometry reconstruction remain CPU stages.
    @discardableResult public func applyPattern(
        _ pattern: LayoutPatternType,
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared
    ) -> Self {
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

    @discardableResult public func applyStandardOrganic(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        iterations: Int = 600,
        repulsionForce: Float = 100,
        attractionForce: Float = 0.05
    ) -> Self {
        var configuration = OrganicLayoutConfiguration()
        configuration.iterations = iterations
        configuration.repulsionForce = repulsionForce
        configuration.attractionForce = attractionForce
        let core = OrganicLayoutOperation(backend: backend, executor: executor, configuration: configuration)
        return groupedPreset(core, routing: .polyline, backend: backend, executor: executor)
    }

    @discardableResult public func applyProgressiveRefinement(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        organicIterations: Int = 600,
        barycenterIterations: Int = 10
    ) -> Self {
        let core = AsyncPresetPlacement { builder in
            builder.useOrganic(backend: backend, executor: executor) {
                $0.iterations = organicIterations
                $0.initialization = .current
            }
            .useBarycenter(backend: backend, executor: executor) { $0.iterations = barycenterIterations }
            .useRemoveOverlaps(backend: backend, executor: executor)
            .transform {
                pullLeavesToNeighbours($0)
                packAroundLargestComponent($0)
            }
        }
        return groupedPreset(core, routing: .polyline, backend: backend, executor: executor)
    }

    @discardableResult public func applyHybridLayout(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        organicIterations: Int = 20
    ) -> Self {
        let core = AsyncPresetPlacement(preserving: [GraphMetadataKeys.layoutSubset]) { builder in
            builder.useHierarchical(backend: backend, executor: executor) { $0.routesEdges = false }
                .transform { graph in
                    let a = Adjacency(graph)
                    for i in a.nodes.indices {
                        a.nodes[i].metadata[GraphMetadataKeys.layoutSubset] = a.neighbors[i].count <= 1
                    }
                }
                .useOrganic(backend: backend, executor: executor) {
                    $0.iterations = organicIterations
                    $0.scope = .subset
                    $0.initialization = .current
                }
        }
        return groupedPreset(core, routing: .polyline, backend: backend, executor: executor)
    }

    @discardableResult public func applyWithEdgeBundling(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        k: Float = 0.1
    ) -> Self {
        routePolyline(backend: backend, executor: executor)
            .routeWithBundling(backend: backend, executor: executor) { $0.k = k }
            .finishRoutes(style: .polyline, backend: backend, executor: executor)
    }

    @discardableResult public func applyNetworkTopology(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        hubCount: Int = 3,
        organicIterations: Int = 600
    ) -> Self {
        let core = AsyncPresetPlacement(preserving: [GraphMetadataKeys.fixed, GraphMetadataKeys.layoutSubset]) {
            builder in
            builder.analyzePageRank(backend: backend, executor: executor)
                .transform { positionNetworkHubs($0, hubCount: hubCount) }
                .useOrganic(backend: backend, executor: executor) {
                    $0.scope = .subset
                    $0.iterations = organicIterations
                }
        }
        return groupedPreset(core, routing: .bundled(0.1), backend: backend, executor: executor)
    }

    @discardableResult public func applySocialNetwork(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        organicIterations: Int = 600,
        repulsionForce: Float = 100
    ) -> Self {
        let core = AsyncPresetPlacement { builder in
            builder.analyzeClusters(backend: backend, executor: executor)
                .useOrganic(backend: backend, executor: executor) {
                    $0.iterations = organicIterations
                    $0.repulsionForce = repulsionForce
                }
        }
        return groupedPreset(core, routing: .bundled(0.1), backend: backend, executor: executor)
    }

    @discardableResult public func applyLargeGraphPreset(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared
    ) -> Self {
        groupedPreset(
            OrganicLayoutOperation(backend: backend, executor: executor),
            routing: .polyline,
            backend: backend,
            executor: executor
        )
    }

    @discardableResult public func applyDenseGraphPreset(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared
    ) -> Self {
        groupedPreset(
            OrganicLayoutOperation(backend: backend, executor: executor),
            routing: .bundled(0.05),
            backend: backend,
            executor: executor
        )
    }
}

extension LayoutBuilder {
    @discardableResult public func applyStandardHierarchical(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        nodeSeparation: Float = 80,
        rankSeparation: Float = 120
    ) -> Self {
        var configuration = HierarchicalLayoutConfiguration()
        configuration.nodeSeparation = nodeSeparation
        configuration.layerSeparation = rankSeparation
        let core = HierarchicalLayoutOperation(backend: backend, executor: executor, configuration: configuration)
        return groupedPreset(core, routing: .layered, backend: backend, executor: executor)
    }

    @discardableResult public func applyStandardTree(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        nodeSeparation: Float = 50,
        levelSeparation: Float = 50
    ) -> Self {
        var configuration = TreeLayoutConfiguration()
        configuration.nodeSeparation = nodeSeparation
        configuration.levelSeparation = levelSeparation
        let core = TreeLayoutOperation(style: .tree, backend: backend, executor: executor, configuration: configuration)
        return groupedPreset(core, routing: .polyline, backend: backend, executor: executor)
    }

    @discardableResult public func applyStandardCircular(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        radius: Float = 300
    ) -> Self {
        var configuration = BasicLayoutConfiguration()
        configuration.radius = radius
        let core = BasicLayoutOperation(
            style: .circular,
            backend: backend,
            executor: executor,
            configuration: configuration
        )
        // `radius` is a minimum for the outer ring only; nested rings take just the radius their members need.
        var nestedConfiguration = configuration
        nestedConfiguration.radius = 0
        let nested = BasicLayoutOperation(
            style: .circular,
            backend: backend,
            executor: executor,
            configuration: nestedConfiguration
        )
        return groupedPreset(core, nested: nested, routing: .polyline, backend: backend, executor: executor)
    }

    @discardableResult public func applyEnterpriseArchitecture(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        nodeSeparation: Float = 80,
        layerSeparation: Float = 120,
        componentSpacing: Float = 50
    ) -> Self {
        // BSP reroutes every owned edge, so the core's own layered routes would be discarded unseen.
        var configuration = HierarchicalLayoutConfiguration()
        configuration.nodeSeparation = nodeSeparation
        configuration.layerSeparation = layerSeparation
        configuration.routesEdges = false
        let core = HierarchicalLayoutOperation(backend: backend, executor: executor, configuration: configuration)
        let components = ComponentLayoutOperation(core, backend: backend, executor: executor)
        components.componentSpacing = componentSpacing
        components.preferredAspectRatio = 1.5
        return analyzePageRank(backend: backend, executor: executor)
            .groupedPreset(components, routing: .bsp, backend: backend, executor: executor)
    }

    @discardableResult public func applyCallGraph(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        nodeSeparation: Float = 60,
        layerSeparation: Float = 150
    ) -> Self {
        var configuration = HierarchicalLayoutConfiguration()
        configuration.nodeSeparation = nodeSeparation
        configuration.layerSeparation = layerSeparation
        let core = HierarchicalLayoutOperation(backend: backend, executor: executor, configuration: configuration)
        return groupedPreset(core, routing: .curves(2), backend: backend, executor: executor)
    }

    @discardableResult public func applyOrganizationChart(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        siblingDistance: Float = 40,
        layerDistance: Float = 80
    ) -> Self {
        let core = AsyncPresetPlacement { builder in
            builder.useOrgChart(backend: backend, executor: executor) {
                $0.siblingDistance = siblingDistance
                $0.layerDistance = layerDistance
            }
        }
        return groupedPreset(core, routing: .polyline, backend: backend, executor: executor)
    }

    @discardableResult public func applyDataFlow(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        nodeSeparation: Float = 100,
        layerSeparation: Float = 150
    ) -> Self {
        var configuration = HierarchicalLayoutConfiguration()
        configuration.nodeSeparation = nodeSeparation
        configuration.layerSeparation = layerSeparation
        configuration.routesEdges = false
        let core = HierarchicalLayoutOperation(backend: backend, executor: executor, configuration: configuration)
        return groupedPreset(core, routing: .channel, backend: backend, executor: executor)
    }

    @discardableResult public func applySmallGraphPreset(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared
    ) -> Self {
        var configuration = HierarchicalLayoutConfiguration()
        configuration.nodeSeparation = 80
        configuration.layerSeparation = 120
        return groupedPreset(
            HierarchicalLayoutOperation(backend: backend, executor: executor, configuration: configuration),
            routing: .curves(3),
            backend: backend,
            executor: executor
        )
    }

    @discardableResult public func applyMediumGraphPreset(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared
    ) -> Self {
        var configuration = HierarchicalLayoutConfiguration()
        configuration.nodeSeparation = 60
        configuration.layerSeparation = 100
        return groupedPreset(
            HierarchicalLayoutOperation(backend: backend, executor: executor, configuration: configuration),
            routing: .layered,
            backend: backend,
            executor: executor
        )
    }

    @discardableResult public func applyWithSmoothCurves(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        curveFittingIterations: Int = 3
    ) -> Self {
        routePolyline(backend: backend, executor: executor)
            .finishRoutes(
                style: .curved,
                backend: backend,
                executor: executor,
                curveIterations: curveFittingIterations
            )
    }

    @discardableResult public func applyWithBspRouting(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared
    ) -> Self {
        routeBsp(backend: backend, executor: executor)
            .finishRoutes(style: .orthogonal, backend: backend, executor: executor)
    }

    @discardableResult public func applyGrainSwimlane(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        laneAssignment: [String: Int],
        laneWidth: Float = 200,
        laneSpacing: Float = 20,
        laneInternalPadding: Float = 20,
        nodeVerticalSpacing: Float = 40
    ) -> Self {
        useSwimlane(backend: backend, executor: executor) {
            $0.laneAssignment = laneAssignment
            $0.laneWidth = laneWidth
            $0.laneSpacing = laneSpacing
            $0.laneInternalPadding = laneInternalPadding
            $0.nodeVerticalSpacing = nodeVerticalSpacing
        }
        .routeChannel(backend: backend, executor: executor)
        .separateEdges(backend: backend, executor: executor)
        .finishRoutes(style: .curved, backend: backend, executor: executor)
    }
}
