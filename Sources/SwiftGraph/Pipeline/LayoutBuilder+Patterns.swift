import Foundation

extension LayoutBuilder {
    @discardableResult public func applyPattern(_ pattern: LayoutPatternType) -> Self {
        switch pattern {
        case .standardHierarchical: applyStandardHierarchical()
        case .standardOrganic: applyStandardOrganic()
        case .standardTree: applyStandardTree()
        case .standardCircular: applyStandardCircular()
        case .progressiveRefinement: applyProgressiveRefinement()
        case .hybridLayout: applyHybridLayout()
        case .enterpriseArchitecture: applyEnterpriseArchitecture()
        case .networkTopology: applyNetworkTopology()
        case .callGraph: applyCallGraph()
        case .socialNetwork: applySocialNetwork()
        case .organizationChart: applyOrganizationChart()
        case .dataFlow: applyDataFlow()
        case .mindMap: applyMindMap()
        case .smallGraphPreset: applySmallGraphPreset()
        case .mediumGraphPreset: applyMediumGraphPreset()
        case .largeGraphPreset: applyLargeGraphPreset()
        case .denseGraphPreset: applyDenseGraphPreset()
        }
    }

    @discardableResult public func applyStandardHierarchical(
        nodeSeparation: Float = 80,
        rankSeparation: Float = 120
    ) -> Self {
        let layout = HierarchicalLayoutAlgorithm()
        layout.nodeSeparation = nodeSeparation
        layout.layerSeparation = rankSeparation
        return groupedPreset(layout, routing: .layered)
    }

    @discardableResult public func applyStandardOrganic(
        iterations: Int = 600,
        repulsionForce: Float = 100,
        attractionForce: Float = 0.05
    ) -> Self {
        let layout = OrganicLayoutAlgorithm()
        layout.iterations = Float(iterations)
        layout.repulsionForce = repulsionForce
        layout.attractionForce = attractionForce
        return groupedPreset(layout, routing: .polyline)
    }

    @discardableResult public func applyStandardTree(nodeSeparation: Float = 50, levelSeparation: Float = 50) -> Self {
        let layout = TreeLayoutAlgorithm()
        layout.nodeSeparation = nodeSeparation
        layout.levelSeparation = levelSeparation
        return groupedPreset(layout, routing: .polyline)
    }

    @discardableResult public func applyStandardCircular(radius: Float = 300) -> Self {
        let layout = CircularLayoutAlgorithm()
        layout.radius = radius
        // `radius` is a minimum for the outer ring only; nested rings take just the radius their members need.
        let nested = CircularLayoutAlgorithm()
        nested.radius = 0
        return groupedPreset(layout, nested: nested, routing: .polyline)
    }

    @discardableResult public func applyProgressiveRefinement(
        organicIterations: Int = 600,
        barycenterIterations: Int = 10
    ) -> Self {
        let core = PresetPlacement { graph in
            let organic = OrganicLayoutAlgorithm()
            organic.iterations = Float(organicIterations)
            organic.initialization = .current
            try organic.applyLayout(graph)
            let barycenter = BarycenterLayoutAlgorithm()
            barycenter.iterations = barycenterIterations
            try barycenter.applyLayout(graph)
            try RemoveOverlapsLayoutAlgorithm().applyLayout(graph)
            pullLeavesToNeighbours(graph)
            packAroundLargestComponent(graph)
        }
        return groupedPreset(core, routing: .polyline)
    }

    @discardableResult public func applyHybridLayout(organicIterations: Int = 20) -> Self {
        let core = PresetPlacement { graph in
            let hierarchy = HierarchicalLayoutAlgorithm()
            hierarchy.routesEdges = false
            try hierarchy.applyLayout(graph)
            let old = graph.nodes.map { $0.metadata[GraphMetadataKeys.layoutSubset] }
            defer {
                for (node, value) in zip(graph.nodes, old) { node.metadata[GraphMetadataKeys.layoutSubset] = value }
            }
            let a = Adjacency(graph)
            for i in a.nodes.indices { a.nodes[i].metadata[GraphMetadataKeys.layoutSubset] = a.neighbors[i].count <= 1 }
            let organic = OrganicLayoutAlgorithm()
            organic.iterations = Float(organicIterations)
            organic.scope = .subset
            organic.initialization = .current
            try organic.applyLayout(graph)
        }
        return groupedPreset(core, routing: .polyline)
    }

    @discardableResult public func applyWithEdgeBundling(k: Float = 0.1) -> Self {
        routePolyline().routeWithBundling { $0.k = k }.finishRoutes(style: .polyline)
    }

    @discardableResult public func applyWithSmoothCurves(curveFittingIterations: Int = 3) -> Self {
        routePolyline().finishRoutes(style: .curved, curveIterations: curveFittingIterations)
    }

    @discardableResult public func applyWithBspRouting() -> Self {
        routeBsp().finishRoutes(style: .orthogonal)
    }

    @discardableResult public func applyEnterpriseArchitecture(
        nodeSeparation: Float = 80,
        layerSeparation: Float = 120,
        componentSpacing: Float = 50
    ) -> Self {
        // BSP reroutes every owned edge, so the core's own layered routes would be discarded unseen.
        let core = HierarchicalLayoutAlgorithm()
        core.nodeSeparation = nodeSeparation
        core.layerSeparation = layerSeparation
        core.routesEdges = false
        let components = ComponentLayout(core)
        components.componentSpacing = componentSpacing
        components.preferredAspectRatio = 1.5
        return analyzePageRank().groupedPreset(components, routing: .bsp)
    }

    @discardableResult public func applyNetworkTopology(hubCount: Int = 3, organicIterations: Int = 600) -> Self {
        groupedPreset(
            PresetPlacement { try networkPlacement($0, hubCount: hubCount, iterations: organicIterations) },
            routing: .bundled(0.1)
        )
    }

    @discardableResult public func applyCallGraph(nodeSeparation: Float = 60, layerSeparation: Float = 150) -> Self {
        let core = HierarchicalLayoutAlgorithm()
        core.nodeSeparation = nodeSeparation
        core.layerSeparation = layerSeparation
        return groupedPreset(core, routing: .curves(2))
    }

    @discardableResult public func applyGrainSwimlane(
        laneAssignment: [String: Int],
        laneWidth: Float = 200,
        laneSpacing: Float = 20,
        laneInternalPadding: Float = 20,
        nodeVerticalSpacing: Float = 40
    ) -> Self {
        useSwimlane {
            $0.laneAssignment = laneAssignment
            $0.laneWidth = laneWidth
            $0.laneSpacing = laneSpacing
            $0.laneInternalPadding = laneInternalPadding
            $0.nodeVerticalSpacing = nodeVerticalSpacing
        }
        .routeChannel().separateEdges().finishRoutes(style: .curved)
    }

    @discardableResult public func applySocialNetwork(organicIterations: Int = 600, repulsionForce: Float = 100) -> Self
    {
        let core = PresetPlacement { graph in
            try LabelPropagationClusteringAlgorithm().applyLayout(graph)
            let organic = OrganicLayoutAlgorithm()
            organic.iterations = Float(organicIterations)
            organic.repulsionForce = repulsionForce
            try organic.applyLayout(graph)
        }
        return groupedPreset(core, routing: .bundled(0.1))
    }

    @discardableResult public func applyOrganizationChart(
        siblingDistance: Float = 40,
        layerDistance: Float = 80
    ) -> Self {
        let core = PresetPlacement { graph in
            let layout = OrgChartLayoutAlgorithm()
            layout.siblingDistance = siblingDistance
            layout.layerDistance = layerDistance
            try layout.applyLayout(graph)
        }
        return groupedPreset(core, routing: .polyline)
    }

    @discardableResult public func applyDataFlow(nodeSeparation: Float = 100, layerSeparation: Float = 150) -> Self {
        let core = HierarchicalLayoutAlgorithm()
        core.nodeSeparation = nodeSeparation
        core.layerSeparation = layerSeparation
        core.routesEdges = false
        return groupedPreset(core, routing: .channel)
    }

    @discardableResult public func applyMindMap(layerDistance: Float = 100) -> Self {
        let core = RadialTreeLayoutAlgorithm()
        core.layerDistance = layerDistance
        return groupedPreset(core, routing: .polyline)
    }

    @discardableResult public func wrapWithComponentHandling(
        _ core: any LayoutAlgorithm,
        componentSpacing: Float = 20,
        preferredAspectRatio: Float = 1
    ) -> Self {
        let layout = ComponentLayout(core)
        layout.componentSpacing = componentSpacing
        layout.preferredAspectRatio = preferredAspectRatio
        return useAlgorithm(layout)
    }

    @discardableResult public func wrapWithRecursiveGroups(
        _ core: any LayoutAlgorithm,
        configure: (RecursiveGroupLayout) -> Void = { _ in }
    ) -> Self {
        let layout = RecursiveGroupLayout(core)
        configure(layout)
        return useAlgorithm(layout)
    }

    @discardableResult public func wrapWithFullComposition(
        _ core: any LayoutAlgorithm,
        componentSpacing: Float = 20,
        configure: (RecursiveGroupLayout) -> Void = { _ in }
    ) -> Self {
        let components = ComponentLayout(core)
        components.componentSpacing = componentSpacing
        let groups = RecursiveGroupLayout(components)
        configure(groups)
        return useAlgorithm(groups)
    }

    @discardableResult public func applyImportanceBased(_ layout: any LayoutAlgorithm) -> Self {
        analyzePageRank()
            .transform { graph in
                for node in graph.nodes {
                    let scale = Float(1 + 2 * (node.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0))
                    node.width *= scale
                    node.height *= scale
                }
            }
            .useAlgorithm(layout).routePolyline().finishRoutes(style: .polyline)
    }

    @discardableResult public func applyClusterBased(_ layout: any LayoutAlgorithm) -> Self {
        analyzeClusters()
            .transform { graph in
                var groups: [Int: [LayoutNode]] = [:]
                var order: [Int] = []
                for (i, node) in graph.nodes.enumerated() {
                    let id = node.metadata[GraphMetadataKeys.cluster] as? Int ?? (-i - 1)
                    if groups[id] == nil { order.append(id) }
                    groups[id, default: []].append(node)
                }
                var graphs: [LayoutGraph] = []
                for id in order {
                    try Task.checkCancellation()
                    let g = subgraph(graph, nodes: groups[required: id])
                    try layout.applyLayout(g)
                    let b = g.bounds
                    translate(g, by: Point(x: -b.x, y: -b.y))
                    graphs.append(g)
                }
                let width = max(400, sqrt(graphs.reduce(Float(0)) { $0 + $1.bounds.width * $1.bounds.height }) * 1.5)
                var x: Float = 0.0
                var y: Float = 0.0
                var rowHeight: Float = 0.0
                for g in graphs {
                    let b = g.bounds
                    if x > 0 && x + b.width > width {
                        x = 0
                        y += rowHeight + 80
                        rowHeight = 0
                    }
                    translate(g, by: Point(x: x, y: y))
                    x += b.width + 80
                    rowHeight = max(rowHeight, b.height)
                }
            }
            .routePolyline().finishRoutes(style: .polyline)
    }

    @discardableResult public func applySmallGraphPreset() -> Self {
        let core = HierarchicalLayoutAlgorithm()
        core.nodeSeparation = 80
        core.layerSeparation = 120
        return groupedPreset(core, routing: .curves(3))
    }

    @discardableResult public func applyMediumGraphPreset() -> Self {
        let core = HierarchicalLayoutAlgorithm()
        core.nodeSeparation = 60
        core.layerSeparation = 100
        return groupedPreset(core, routing: .layered)
    }

    @discardableResult public func applyLargeGraphPreset() -> Self {
        groupedPreset(OrganicLayoutAlgorithm(), routing: .polyline)
    }

    @discardableResult public func applyDenseGraphPreset() -> Self {
        groupedPreset(OrganicLayoutAlgorithm(), routing: .bundled(0.05))
    }
}
