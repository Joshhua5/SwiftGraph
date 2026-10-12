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
    @discardableResult func applyStandardHierarchical(nodeSeparation: Double = 80, rankSeparation: Double = 120) -> Self {
        let layout = HierarchicalLayoutAlgorithm(); layout.nodeSeparation = nodeSeparation; layout.layerSeparation = rankSeparation
        return useAlgorithm(RecursiveGroupLayout(layout)).separateEdges().routeSelfLoops()
    }
    @discardableResult func applyStandardOrganic(iterations: Int = 600, repulsionForce: Double = 100, attractionForce: Double = 0.05) -> Self {
        let layout = OrganicLayoutAlgorithm(); layout.iterations = Double(iterations); layout.repulsionForce = repulsionForce; layout.attractionForce = attractionForce
        return useAlgorithm(RecursiveGroupLayout(layout)).routePolyline().routeSelfLoops()
    }
    @discardableResult func applyStandardTree(nodeSeparation: Double = 50, levelSeparation: Double = 50) -> Self {
        let layout = TreeLayoutAlgorithm(); layout.nodeSeparation = nodeSeparation; layout.levelSeparation = levelSeparation
        return useAlgorithm(RecursiveGroupLayout(layout)).routePolyline().routeSelfLoops()
    }
    @discardableResult func applyStandardCircular(radius: Double = 300) -> Self {
        let layout = CircularLayoutAlgorithm(); layout.radius = radius
        return useAlgorithm(RecursiveGroupLayout(layout)).routePolyline().routeSelfLoops()
    }
    @discardableResult func applyProgressiveRefinement(organicIterations: Int = 600, barycenterIterations: Int = 10) -> Self {
        useOrganic { $0.iterations = Double(organicIterations); $0.initialization = .current }.useBarycenter { $0.iterations = barycenterIterations }.removeOverlaps().routePolyline().routeSelfLoops()
    }
    @discardableResult func applyHybridLayout(organicIterations: Int = 20) -> Self {
        useHierarchical().transform { graph in
            let a = Adjacency(graph)
            for i in a.nodes.indices { a.nodes[i].metadata[GraphMetadataKeys.layoutSubset] = a.neighbors[i].count <= 1 }
        }.useOrganic { $0.iterations = Double(organicIterations); $0.scope = .subset; $0.initialization = .current }.routePolyline().routeSelfLoops()
    }
    @discardableResult func applyWithEdgeBundling(k: Double = 0.1) -> Self { routePolyline().routeWithBundling { $0.k = k }.routeSelfLoops() }
    @discardableResult func applyWithSmoothCurves(curveFittingIterations: Int = 3) -> Self { routePolyline().routeCurveFitting { $0.iterations = curveFittingIterations }.routeSelfLoops() }
    @discardableResult func applyWithBspRouting() -> Self { routeBsp().routeSelfLoops() }
    @discardableResult func applyEnterpriseArchitecture(nodeSeparation: Double = 80, layerSeparation: Double = 120, componentSpacing: Double = 50) -> Self {
        let core = HierarchicalLayoutAlgorithm(); core.nodeSeparation = nodeSeparation; core.layerSeparation = layerSeparation
        let components = ComponentLayout(core); components.componentSpacing = componentSpacing; components.preferredAspectRatio = 1.5
        return analyzePageRank().useAlgorithm(RecursiveGroupLayout(components)).routeBsp().separateEdges().routeSelfLoops()
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
                let angle = 2 * Double.pi * Double(i) / Double(hubs.count)
                hub.center = Point(x: 300 * cos(angle), y: 300 * sin(angle))
            }
            let fixed = Set(hubs)
            for node in graph.nodes { node.metadata[GraphMetadataKeys.layoutSubset] = !fixed.contains(node) }
        }.useOrganic { $0.scope = .subset; $0.iterations = Double(organicIterations) }.routeWithBundling().routeSelfLoops()
    }
    @discardableResult func applyCallGraph(nodeSeparation: Double = 60, layerSeparation: Double = 150) -> Self {
        useHierarchical { $0.nodeSeparation = nodeSeparation; $0.layerSeparation = layerSeparation }.removeOverlaps().separateEdges().routeCurveFitting().routeSelfLoops()
    }
    @discardableResult func applyGrainSwimlane(laneAssignment: [String: Int], laneWidth: Double = 200, laneSpacing: Double = 20, laneInternalPadding: Double = 20, nodeVerticalSpacing: Double = 40) -> Self {
        useSwimlane {
            $0.laneAssignment = laneAssignment; $0.laneWidth = laneWidth; $0.laneSpacing = laneSpacing
            $0.laneInternalPadding = laneInternalPadding; $0.nodeVerticalSpacing = nodeVerticalSpacing
        }.routeChannel().separateEdges().routeCurveFitting().routeSelfLoops()
    }
    @discardableResult func applySocialNetwork(organicIterations: Int = 600, repulsionForce: Double = 100) -> Self {
        analyzeClusters().useOrganic { $0.iterations = Double(organicIterations); $0.repulsionForce = repulsionForce }.routeWithBundling().routeSelfLoops()
    }
    @discardableResult func applyOrganizationChart(siblingDistance: Double = 40, layerDistance: Double = 80) -> Self {
        useOrgChart { $0.siblingDistance = siblingDistance; $0.layerDistance = layerDistance }.routePolyline().routeSelfLoops()
    }
    @discardableResult func applyDataFlow(nodeSeparation: Double = 100, layerSeparation: Double = 150) -> Self {
        useHierarchical { $0.nodeSeparation = nodeSeparation; $0.layerSeparation = layerSeparation }.routeChannel().separateEdges().routeSelfLoops()
    }
    @discardableResult func applyMindMap(layerDistance: Double = 100) -> Self { useRadialTree { $0.layerDistance = layerDistance }.routePolyline().routeSelfLoops() }
    @discardableResult func wrapWithComponentHandling(_ core: any LayoutAlgorithm, componentSpacing: Double = 20, preferredAspectRatio: Double = 1) -> Self {
        let layout = ComponentLayout(core); layout.componentSpacing = componentSpacing; layout.preferredAspectRatio = preferredAspectRatio
        return useAlgorithm(layout)
    }
    @discardableResult func wrapWithRecursiveGroups(_ core: any LayoutAlgorithm) -> Self { useAlgorithm(RecursiveGroupLayout(core)) }
    @discardableResult func wrapWithFullComposition(_ core: any LayoutAlgorithm, componentSpacing: Double = 20) -> Self {
        let components = ComponentLayout(core); components.componentSpacing = componentSpacing
        return useAlgorithm(RecursiveGroupLayout(components))
    }
    @discardableResult func applyImportanceBased(_ layout: any LayoutAlgorithm) -> Self {
        analyzePageRank().transform { graph in
            for node in graph.nodes {
                let scale = 1 + 2 * (node.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0)
                node.width *= scale; node.height *= scale
            }
        }.useAlgorithm(layout).routePolyline().routeSelfLoops()
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
            let width = max(400, sqrt(graphs.reduce(0.0) { $0 + $1.bounds.width * $1.bounds.height }) * 1.5)
            var x = 0.0, y = 0.0, rowHeight = 0.0
            for g in graphs {
                let b = g.bounds
                if x > 0 && x + b.width > width { x = 0; y += rowHeight + 80; rowHeight = 0 }
                translate(g, by: Point(x: x, y: y)); x += b.width + 80; rowHeight = max(rowHeight, b.height)
            }
        }.routePolyline().routeSelfLoops()
    }
    @discardableResult func applySmallGraphPreset() -> Self {
        useHierarchical { $0.nodeSeparation = 80; $0.layerSeparation = 120 }.removeOverlaps().separateEdges().routeCurveFitting { $0.iterations = 3 }.routeSelfLoops()
    }
    @discardableResult func applyMediumGraphPreset() -> Self { useHierarchical { $0.nodeSeparation = 60; $0.layerSeparation = 100 }.separateEdges().routeSelfLoops() }
    @discardableResult func applyLargeGraphPreset() -> Self { useOrganic().routePolyline().routeSelfLoops() }
    @discardableResult func applyDenseGraphPreset() -> Self { useOrganic().routePolyline().routeWithBundling { $0.k = 0.05 }.routeSelfLoops() }
}
