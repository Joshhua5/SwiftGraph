import Foundation

public enum LayoutPatternType: String, CaseIterable, Sendable {
    case standardHierarchical, standardOrganic, standardTree, standardCircular
    case progressiveRefinement, hybridLayout
    case enterpriseArchitecture, networkTopology, callGraph, socialNetwork, organizationChart, dataFlow, mindMap
    case smallGraphPreset, mediumGraphPreset, largeGraphPreset, denseGraphPreset
}

public extension LayoutBuilder {
    @discardableResult func applyPattern(_ pattern: LayoutPatternType) -> Self {
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
    @discardableResult func applyStandardHierarchical(nodeSeparation: Float = 80, rankSeparation: Float = 120) -> Self {
        let layout = HierarchicalLayoutAlgorithm(); layout.nodeSeparation = nodeSeparation; layout.layerSeparation = rankSeparation
        return useAlgorithm(RecursiveGroupLayout(layout)).separateEdges().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applyStandardOrganic(iterations: Int = 600, repulsionForce: Float = 100, attractionForce: Float = 0.05) -> Self {
        let layout = OrganicLayoutAlgorithm(); layout.iterations = Float(iterations); layout.repulsionForce = repulsionForce; layout.attractionForce = attractionForce
        return useAlgorithm(RecursiveGroupLayout(layout)).routePolyline().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applyStandardTree(nodeSeparation: Float = 50, levelSeparation: Float = 50) -> Self {
        let layout = TreeLayoutAlgorithm(); layout.nodeSeparation = nodeSeparation; layout.levelSeparation = levelSeparation
        return useAlgorithm(RecursiveGroupLayout(layout)).routePolyline().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applyStandardCircular(radius: Float = 300) -> Self {
        let layout = CircularLayoutAlgorithm(); layout.radius = radius
        return useAlgorithm(RecursiveGroupLayout(layout)).routePolyline().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applyProgressiveRefinement(organicIterations: Int = 600, barycenterIterations: Int = 10) -> Self {
        useOrganic { $0.iterations = Float(organicIterations); $0.initialization = .current }.useBarycenter { $0.iterations = barycenterIterations }.removeOverlaps().routePolyline().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applyHybridLayout(organicIterations: Int = 20) -> Self {
        useHierarchical().transform { graph in
            let a = Adjacency(graph)
            for i in a.nodes.indices { a.nodes[i].metadata[GraphMetadataKeys.layoutSubset] = a.neighbors[i].count <= 1 }
        }.useOrganic { $0.iterations = Float(organicIterations); $0.scope = .subset; $0.initialization = .current }.routePolyline().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applyWithEdgeBundling(k: Float = 0.1) -> Self { routePolyline().routeWithBundling { $0.k = k }.routeSelfLoops().clipEdgeEndpoints().distributePorts() }
    @discardableResult func applyWithSmoothCurves(curveFittingIterations: Int = 3) -> Self { routePolyline().clipEdgeEndpoints().distributePorts().routeCurveFitting { $0.iterations = curveFittingIterations }.routeSelfLoops().clipEdgeEndpoints() }
    @discardableResult func applyWithBspRouting() -> Self { routeBsp().routeSelfLoops().clipEdgeEndpoints().distributePorts() }
    @discardableResult func applyEnterpriseArchitecture(nodeSeparation: Float = 80, layerSeparation: Float = 120, componentSpacing: Float = 50) -> Self {
        let core = HierarchicalLayoutAlgorithm(); core.nodeSeparation = nodeSeparation; core.layerSeparation = layerSeparation
        let components = ComponentLayout(core); components.componentSpacing = componentSpacing; components.preferredAspectRatio = 1.5
        return analyzePageRank().useAlgorithm(RecursiveGroupLayout(components)).routeBsp().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applyNetworkTopology(hubCount: Int = 3, organicIterations: Int = 600) -> Self {
        analyzePageRank().transform { graph in
            let hubs = graph.nodes.enumerated().sorted { a, b in
                let left = a.element.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0
                let right = b.element.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0
                return left == right ? a.offset < b.offset : left > right
            }.prefix(max(0, hubCount)).map(\.element)
            for (i, hub) in hubs.enumerated() {
                hub.metadata[GraphMetadataKeys.fixed] = true
                let angle = 2 * Float.pi * Float(i) / Float(hubs.count)
                hub.center = Point(x: 300 * cos(angle), y: 300 * sin(angle))
            }
            let fixed = Set(hubs)
            for node in graph.nodes { node.metadata[GraphMetadataKeys.layoutSubset] = !fixed.contains(node) }
        }.useOrganic { $0.scope = .subset; $0.iterations = Float(organicIterations) }.routeWithBundling().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applyCallGraph(nodeSeparation: Float = 60, layerSeparation: Float = 150) -> Self {
        useHierarchical { $0.nodeSeparation = nodeSeparation; $0.layerSeparation = layerSeparation }.removeOverlaps().separateEdges().clipEdgeEndpoints().distributePorts().routeCurveFitting().routeSelfLoops().clipEdgeEndpoints()
    }
    @discardableResult func applyGrainSwimlane(laneAssignment: [String: Int], laneWidth: Float = 200, laneSpacing: Float = 20, laneInternalPadding: Float = 20, nodeVerticalSpacing: Float = 40) -> Self {
        useSwimlane {
            $0.laneAssignment = laneAssignment; $0.laneWidth = laneWidth; $0.laneSpacing = laneSpacing
            $0.laneInternalPadding = laneInternalPadding; $0.nodeVerticalSpacing = nodeVerticalSpacing
        }.routeChannel().separateEdges().clipEdgeEndpoints().distributePorts().routeCurveFitting().routeSelfLoops().clipEdgeEndpoints()
    }
    @discardableResult func applySocialNetwork(organicIterations: Int = 600, repulsionForce: Float = 100) -> Self {
        analyzeClusters().useOrganic { $0.iterations = Float(organicIterations); $0.repulsionForce = repulsionForce }.routeWithBundling().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applyOrganizationChart(siblingDistance: Float = 40, layerDistance: Float = 80) -> Self {
        useOrgChart { $0.siblingDistance = siblingDistance; $0.layerDistance = layerDistance }.routePolyline().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applyDataFlow(nodeSeparation: Float = 100, layerSeparation: Float = 150) -> Self {
        useHierarchical { $0.nodeSeparation = nodeSeparation; $0.layerSeparation = layerSeparation }.routeChannel().separateEdges().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applyMindMap(layerDistance: Float = 100) -> Self { useRadialTree { $0.layerDistance = layerDistance }.routePolyline().routeSelfLoops().clipEdgeEndpoints().distributePorts() }
    @discardableResult func wrapWithComponentHandling(_ core: any LayoutAlgorithm, componentSpacing: Float = 20, preferredAspectRatio: Float = 1) -> Self {
        let layout = ComponentLayout(core); layout.componentSpacing = componentSpacing; layout.preferredAspectRatio = preferredAspectRatio
        return useAlgorithm(layout)
    }
    @discardableResult func wrapWithRecursiveGroups(_ core: any LayoutAlgorithm,
        configure: (RecursiveGroupLayout) -> Void = { _ in }) -> Self {
        let layout = RecursiveGroupLayout(core); configure(layout); return useAlgorithm(layout)
    }
    @discardableResult func wrapWithFullComposition(_ core: any LayoutAlgorithm, componentSpacing: Float = 20,
        configure: (RecursiveGroupLayout) -> Void = { _ in }) -> Self {
        let components = ComponentLayout(core); components.componentSpacing = componentSpacing
        let groups = RecursiveGroupLayout(components); configure(groups); return useAlgorithm(groups)
    }
    @discardableResult func applyImportanceBased(_ layout: any LayoutAlgorithm) -> Self {
        analyzePageRank().transform { graph in
            for node in graph.nodes {
                let scale = Float(1 + 2 * (node.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0))
                node.width *= scale; node.height *= scale
            }
        }.useAlgorithm(layout).routePolyline().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applyClusterBased(_ layout: any LayoutAlgorithm) -> Self {
        analyzeClusters().transform { graph in
            var groups: [Int: [LayoutNode]] = [:], order: [Int] = []
            for (i, node) in graph.nodes.enumerated() {
                let id = node.metadata[GraphMetadataKeys.cluster] as? Int ?? (-i - 1)
                if groups[id] == nil { order.append(id) }; groups[id, default: []].append(node)
            }
            var graphs: [LayoutGraph] = []
            for id in order {
                try Task.checkCancellation()
                let g = subgraph(graph, nodes: groups[id]!); try layout.applyLayout(g)
                let b = g.bounds; translate(g, by: Point(x: -b.x, y: -b.y)); graphs.append(g)
            }
            let width = max(400, sqrt(graphs.reduce(Float(0)) { $0 + $1.bounds.width * $1.bounds.height }) * 1.5)
            var x: Float = 0.0, y: Float = 0.0, rowHeight: Float = 0.0
            for g in graphs {
                let b = g.bounds
                if x > 0 && x + b.width > width { x = 0; y += rowHeight + 80; rowHeight = 0 }
                translate(g, by: Point(x: x, y: y)); x += b.width + 80; rowHeight = max(rowHeight, b.height)
            }
        }.routePolyline().routeSelfLoops().clipEdgeEndpoints().distributePorts()
    }
    @discardableResult func applySmallGraphPreset() -> Self {
        useHierarchical { $0.nodeSeparation = 80; $0.layerSeparation = 120 }.removeOverlaps().separateEdges().clipEdgeEndpoints().distributePorts().routeCurveFitting { $0.iterations = 3 }.routeSelfLoops().clipEdgeEndpoints()
    }
    @discardableResult func applyMediumGraphPreset() -> Self { useHierarchical { $0.nodeSeparation = 60; $0.layerSeparation = 100 }.separateEdges().routeSelfLoops().clipEdgeEndpoints().distributePorts() }
    @discardableResult func applyLargeGraphPreset() -> Self { useOrganic().routePolyline().routeSelfLoops().clipEdgeEndpoints().distributePorts() }
    @discardableResult func applyDenseGraphPreset() -> Self { useOrganic().routePolyline().routeWithBundling { $0.k = 0.05 }.routeSelfLoops().clipEdgeEndpoints().distributePorts() }
}
