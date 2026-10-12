import Foundation
import Testing
@testable import SwiftGraph

private func sample(_ count: Int = 4) -> LayoutGraph {
    let g = LayoutGraph()
    for i in 0..<count { g.addNode(LayoutNode(id: "n\(i)", width: 40 + Double(i % 3) * 10, height: 30 + Double(i % 2) * 10)) }
    if count > 1 { for i in 1..<count { g.addEdge(LayoutEdge(source: g.nodes[i - 1], target: g.nodes[i])) } }
    return g
}
private func finite(_ g: LayoutGraph) -> Bool {
    g.nodes.allSatisfy { [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) } && g.edges.allSatisfy { $0.path.allSatisfy { $0.x.isFinite && $0.y.isFinite } }
}

@Test func geometryUsesClosedSegmentsAndOpenRectangleOverlap() {
    let r = Rect(x: 10, y: 20, width: 30, height: 40)
    #expect(r.center == Point(x: 25, y: 40))
    #expect(r.contains(Point(x: 40, y: 60)))
    #expect(!r.intersects(Rect(x: 40, y: 20, width: 10, height: 10)))
    #expect(r.intersectsLine(Point(x: 0, y: 40), Point(x: 50, y: 40)))
    #expect(r.intersectsLine(Point(x: 0, y: 20), Point(x: 50, y: 20)))
    #expect(!r.intersectsLine(Point(x: 0, y: 19), Point(x: 50, y: 19)))
}

@Test func detachedSubgraphDoesNotReparentOrRetainParentCycle() {
    let g = sample(), node = g.nodes[0]
    let temp = LayoutGraph(); temp.addNodeDetached(node)
    #expect(node.parent === g.root)
    #expect(temp.root.children == [node])
    weak var root: LayoutNode?
    do { let ephemeral = sample(1); root = ephemeral.root }
    #expect(root == nil)
}

@Test func pageRankPreservesPayloadAndRedistributesDanglingMass() throws {
    let g = sample(3), payload = NSObject()
    g.nodes[0].data = payload
    g.addEdge(LayoutEdge(source: g.nodes[0], target: g.nodes[0]))
    try PageRankAlgorithm().applyLayout(g)
    let values = g.nodes.map { $0.metadata[GraphMetadataKeys.pageRank] as! Double }
    #expect(abs(values.reduce(0, +) - 1) < 1e-10)
    #expect(values.allSatisfy { $0 > 0 && $0.isFinite })
    #expect(g.nodes[0].data as? NSObject === payload)
}

@Test func disconnectedCommunitiesKeepDistinctLabels() throws {
    let g = sample(4); g.edges.remove(at: 1)
    try LabelPropagationClusteringAlgorithm().applyLayout(g)
    let labels = g.nodes.map { $0.metadata[GraphMetadataKeys.cluster] as! Int }
    #expect(labels[0] == labels[1]); #expect(labels[2] == labels[3]); #expect(labels[0] != labels[2])
}

@Test func channelRoutingAvoidsObstacleAndRespectsPorts() {
    let g = sample(3), a = g.nodes[0], obstacle = g.nodes[1], b = g.nodes[2]
    a.bounds = Rect(x: 0, y: 0, width: 40, height: 40)
    obstacle.bounds = Rect(x: 100, y: -20, width: 80, height: 80)
    b.bounds = Rect(x: 260, y: 0, width: 40, height: 40)
    let e = LayoutEdge(source: a, target: b); e.sourcePort = .right; e.targetPort = .left; g.edges = [e]
    let router = ChannelEdgeRouter(); router.routeEdges(g)
    #expect(router.unroutableEdges.isEmpty); #expect(e.path.count >= 4)
    #expect(e.path.first == Point(x: 41, y: 20)); #expect(e.path.last == Point(x: 259, y: 20))
    for (p, q) in zip(e.path, e.path.dropFirst()) {
        #expect(p.x == q.x || p.y == q.y)
        #expect(!obstacle.bounds.intersectsLine(p, q))
    }
    // Ports are one unit outside the selected side; lattice doglegs need not leave normally.
    let first = e.path; router.routeEdges(g); #expect(e.path == first)
}

@Test func clipperUsesActualCrossingSegmentAndIsIdempotent() {
    let g = sample(2), e = g.edges[0]
    e.source.bounds = Rect(width: 100, height: 100); e.target.bounds = Rect(x: 200, y: 0, width: 100, height: 100)
    e.path = [Point(x: 50, y: 50), Point(x: 50, y: 80), Point(x: 150, y: 80), Point(x: 250, y: 80), Point(x: 250, y: 50)]
    EdgeEndpointClipper.clipToNodeBounds(g)
    #expect(e.path.first == Point(x: 100, y: 80)); #expect(e.path.last == Point(x: 200, y: 80))
    let path = e.path; EdgeEndpointClipper.clipToNodeBounds(g); #expect(e.path == path)
}

@Test func generalRoutersPreserveSelfLoops() {
    let g = sample(2); g.nodes[1].x = 300
    let loop = LayoutEdge(source: g.nodes[0], target: g.nodes[0]); g.addEdge(loop)
    SelfLoopRouter().routeEdges(g); let path = loop.path
    let routers: [any EdgeRouter] = [ChannelEdgeRouter(), PolylineEdgeRouter(), BusEdgeRouter(), OctilinearEdgeRouter(), ParallelEdgeRouter(), CurveFittingEdgeRouter(), BspEdgeRouter(), OrthogonalGroupedEdgeRouter(), EdgeBundlingRouter()]
    for router in routers { router.routeEdges(g); #expect(loop.path == path) }
}

@Test func reverseParallelEdgesGetDistinctTracks() {
    let g = sample(2); g.nodes[1].x = 300
    g.addEdge(LayoutEdge(source: g.nodes[0], target: g.nodes[1])); g.addEdge(LayoutEdge(source: g.nodes[1], target: g.nodes[0]))
    ParallelEdgeRouter().routeEdges(g)
    #expect(Set(g.edges.map { $0.path[1] }).count == 3)
    for e in g.edges { #expect(e.path.first == e.source.center); #expect(e.path.last == e.target.center) }
}

@Test func quadTreeFindsStraddlersAndOutsideRootEntries() {
    let tree = QuadTree<String>(bounds: Rect(width: 100, height: 100), capacity: 1)
    tree.insert(bounds: Rect(x: 45, y: 45, width: 20, height: 20), item: "straddler")
    tree.insert(bounds: Rect(x: 10, y: 10, width: 5, height: 5), item: "small")
    tree.insert(bounds: Rect(x: -100, y: -100, width: 10, height: 10), item: "outside")
    #expect(tree.query(Rect(x: 50, y: 50, width: 2, height: 2)) == ["straddler"])
    #expect(tree.query(Rect(x: -100, y: -100, width: 5, height: 5)) == ["outside"])
}

@Test func treesHandleCyclesDisconnectedComponentsAndMixedSizes() throws {
    let algorithms: [any LayoutAlgorithm] = [TreeLayoutAlgorithm(), RadialTreeLayoutAlgorithm(), BalloonLayoutAlgorithm(), RadialLayoutAlgorithm(), RadialStarLayoutAlgorithm(), OrgChartLayoutAlgorithm(), TreeMapLayoutAlgorithm()]
    for algorithm in algorithms {
        let g = sample(6); g.edges.remove(at: 3)
        g.addEdge(LayoutEdge(source: g.nodes[2], target: g.nodes[0])); g.addEdge(LayoutEdge(source: g.nodes[0], target: g.nodes[0]))
        try algorithm.applyLayout(g); #expect(finite(g))
        try algorithm.applyLayout(LayoutGraph())
    }
}

@Test func treeMapPreservesCallerHierarchy() throws {
    let g = sample(4), parents = g.nodes.map(\.parent), children = g.root.children
    try TreeMapLayoutAlgorithm().applyLayout(g)
    #expect(g.nodes.map(\.parent) == parents); #expect(g.root.children == children)
}

@Test func forceQuadTreeExcludesSelfAndHandlesCoincidentBodies() {
    let tree = ForceQuadTree()
    tree.build([.zero]); #expect(tree.computeForce(nodeIndex: 0, position: .zero, repulsionSquared: 100) == .zero)
    tree.build(Array(repeating: .zero, count: 100))
    let force = tree.computeForce(nodeIndex: 0, position: .zero, repulsionSquared: 100)
    #expect(force.x.isFinite && force.y.isFinite); #expect(force.length > 0)
    tree.build([.zero, Point(x: 600, y: 0)])
    #expect(tree.computeForce(nodeIndex: 0, position: .zero, repulsionSquared: 100) == .zero)
}

@Test func hierarchicalLongEdgesKeepBendsAndRankSpacing() throws {
    let g = sample(3), long = LayoutEdge(source: g.nodes[0], target: g.nodes[2]); g.addEdge(long)
    let layout = HierarchicalLayoutAlgorithm(); layout.rankSeparation = 75
    try layout.applyLayout(g)
    #expect(layout.layerSeparation == 75)
    #expect(abs(g.nodes[1].y - g.nodes[0].bounds.bottom - 75) < 1e-9)
    #expect(long.path.count == 3)
    #expect(long.path[1].y == g.nodes[1].center.y)
    #expect(!g.nodes[1].bounds.contains(long.path[1]))
    let centers = g.nodes.map(\.center), paths = g.edges.map(\.path)
    try layout.applyLayout(g)
    #expect(g.nodes.map(\.center) == centers); #expect(g.edges.map(\.path) == paths)
}

@Test func hierarchicalLimitsVirtualChainsAndRankWidth() throws {
    let g = sample(70), e = LayoutEdge(source: g.nodes[0], target: g.nodes[69]); g.addEdge(e)
    try HierarchicalLayoutAlgorithm().applyLayout(g); #expect(e.path.count == 2)
    let flat = sample(12); flat.edges = []
    let layout = HierarchicalLayoutAlgorithm(); layout.maxNodesPerRank = 3
    try layout.applyLayout(flat)
    let rows = Dictionary(grouping: flat.nodes, by: { $0.center.y })
    #expect(rows.values.allSatisfy { $0.count <= 3 })
}

@Test func gridLayoutsRespectNodeSizesAndIgnoreNegativeAssignments() throws {
    for layout in [TabularLayoutAlgorithm() as any LayoutAlgorithm, OrthogonalLayoutAlgorithm(), KandinskyLayoutAlgorithm()] {
        let g = sample(9); g.nodes[0].width = 500; g.nodes[3].height = 400
        try layout.applyLayout(g)
        for i in g.nodes.indices { for j in g.nodes.indices where j > i { #expect(!g.nodes[i].bounds.intersects(g.nodes[j].bounds)) } }
    }
    let g = sample(2), layout = PartitionGridLayoutAlgorithm()
    layout.cellAssignment = ["n0": (-1, 0), "n1": (1, 1)]
    let before = g.nodes[0].bounds; try layout.applyLayout(g)
    #expect(g.nodes[0].bounds == before); #expect(g.nodes[1].x > 0)
}

@Test func organicPreservesFixedAndSubsetNodesExactly() throws {
    let g = sample(3)
    g.nodes[0].x = 123.123456789; g.nodes[0].metadata[GraphMetadataKeys.fixed] = true
    g.nodes[1].x = -20; g.nodes[2].x = 50
    let first = g.nodes[0].bounds, second = g.nodes[1].bounds
    let layout = OrganicLayoutAlgorithm(); layout.scope = .subset; layout.iterations = 10
    g.nodes[2].metadata[GraphMetadataKeys.layoutSubset] = true
    try layout.applyLayout(g)
    #expect(g.nodes[0].bounds == first); #expect(g.nodes[1].bounds == second); #expect(g.nodes[2].x != 50)
    let before = g.nodes.map(\.bounds); layout.iterations = 0; try layout.applyLayout(g)
    #expect(g.nodes.map(\.bounds) == before)
}

@Test func recursiveGroupsTranslateInternalPathsAndRouteCrossGroupEdges() throws {
    let g = LayoutGraph()
    let outer = LayoutNode(id: "outer", width: 1, height: 1); outer.isGroup = true; g.addNode(outer)
    let inner = LayoutNode(id: "inner", width: 1, height: 1); inner.isGroup = true; inner.parent = outer; outer.children.append(inner); g.addNode(inner)
    let a = LayoutNode(id: "a", width: 30, height: 20), b = LayoutNode(id: "b", width: 30, height: 20)
    for node in [a, b] { node.parent = inner; inner.children.append(node); g.addNode(node) }
    let outside = LayoutNode(id: "outside", width: 30, height: 20); g.addNode(outside)
    let internalEdge = LayoutEdge(source: a, target: b), boundary = LayoutEdge(source: b, target: outside)
    g.edges = [internalEdge, boundary]
    try RecursiveGroupLayout(HierarchicalLayoutAlgorithm()).applyLayout(g)
    #expect(inner.bounds.contains(a.center)); #expect(inner.bounds.contains(b.center)); #expect(outer.bounds.contains(inner.center))
    #expect(internalEdge.path.first == a.center); #expect(internalEdge.path.last == b.center)
    #expect(boundary.path.count >= 2); #expect(a.parent === inner); #expect(inner.parent === outer)
}

@Test func subgraphCentroidTranslationIncludesOwnedPaths() throws {
    let g = sample(4); g.nodes[0].x = 400; g.nodes[1].x = 600; g.nodes[2].x = 1000; g.nodes[3].x = 1500
    let fixed = g.nodes[2].bounds, unrelated = [Point(x: 1100, y: -40), Point(x: 1400, y: -40)]
    g.edges[2].path = unrelated
    let centroid = (g.nodes[0].center + g.nodes[1].center) / 2
    let layout = SubgraphLayoutAlgorithm(HierarchicalLayoutAlgorithm()); layout.selectedNodeIds = ["n0", "n1"]
    try layout.applyLayout(g)
    #expect(((g.nodes[0].center + g.nodes[1].center) / 2 - centroid).length < 1e-8)
    #expect(g.edges[0].path.first == g.nodes[0].center); #expect(g.edges[0].path.last == g.nodes[1].center)
    #expect(g.nodes[2].bounds == fixed); #expect(g.edges[2].path == unrelated)
}

@Test func swimlanesExpandForWideNodesAndUseCumulativeRankHeights() throws {
    let g = sample(3); g.nodes[0].width = 400; g.nodes[0].height = 180
    let layout = SwimlaneLayoutAlgorithm(); layout.laneAssignment = ["n0": 0, "n1": 1, "n2": 1]
    try layout.applyLayout(g)
    #expect(layout.computedLanes[0].width >= 440)
    #expect(g.nodes[1].y >= g.nodes[0].bounds.bottom + layout.nodeVerticalSpacing)
    #expect(g.edges[0].sourcePort == .bottom); #expect(g.edges[0].targetPort == .top)
}

@Test func allLayoutsHandleEmptySingletonAndCyclicInput() throws {
    let layouts: [any LayoutAlgorithm] = [HierarchicalLayoutAlgorithm(), SeriesParallelLayoutAlgorithm(), OrganicLayoutAlgorithm(), BarycenterLayoutAlgorithm(), RemoveOverlapsLayoutAlgorithm(), TreeLayoutAlgorithm(), RadialTreeLayoutAlgorithm(), BalloonLayoutAlgorithm(), RadialLayoutAlgorithm(), RadialStarLayoutAlgorithm(), OrthogonalLayoutAlgorithm(), PartitionGridLayoutAlgorithm(), TabularLayoutAlgorithm(), KandinskyLayoutAlgorithm(), CircularLayoutAlgorithm(), SwimlaneLayoutAlgorithm(), TreeMapLayoutAlgorithm(), CompactDiskLayoutAlgorithm(), OrgChartLayoutAlgorithm(), FillAreaLayoutAlgorithm(), ClearAreaLayoutAlgorithm(), AlignmentLayoutAlgorithm(), GivenCoordinatesLayoutAlgorithm(), VerticalStackLayoutAlgorithm(), PageRankAlgorithm(), LabelPropagationClusteringAlgorithm(), ComponentLayout(TreeLayoutAlgorithm()), MultiPageLayoutAlgorithm(), RecursiveGroupLayout(TreeLayoutAlgorithm())]
    for layout in layouts {
        for count in [0, 1, 4] {
            let g = sample(count)
            if let first = g.nodes.first, let last = g.nodes.last { g.addEdge(LayoutEdge(source: last, target: first)); g.addEdge(LayoutEdge(source: first, target: first)) }
            try layout.applyLayout(g); #expect(finite(g), "\(type(of: layout)) produced nonfinite geometry")
        }
    }
}

@Test func builderConfiguresImmediatelyAndExecutesInOrder() async throws {
    let g = sample(3), builder = LayoutBuilder.create(g)
    var configured = false, order: [Int] = []
    builder.useHierarchical { configured = true; $0.layerSeparation = 123 }
        .transform { _ in order.append(1) }.transformAsync { _ in order.append(2) }.routeSelfLoops()
    #expect(configured); #expect(builder.pipelineLength == 4); #expect(builder.graph === g)
    try await builder.applyAsync(); #expect(order == [1, 2]); #expect(g.edges.allSatisfy { $0.path.count >= 2 })
}

@Test func everyPresetProducesFinitePositionedGraphs() async throws {
    for pattern in LayoutPatternType.allCases {
        let g = sample(6); g.addEdge(LayoutEdge(source: g.nodes[0], target: g.nodes[0]))
        try await LayoutBuilder.create(g).applyPattern(pattern).applyAsync()
        #expect(finite(g), "\(pattern) produced nonfinite geometry")
        #expect(g.nodes.contains { $0.x != 0 || $0.y != 0 })
        #expect(g.edges.last!.path.count > 2, "\(pattern) lost a self loop")
        #expect(g.edges.allSatisfy { $0.path.count >= 2 }, "\(pattern) left an edge without a route")
    }
}

@Test func cancellationStopsPipelineBeforeMutation() async throws {
    let cancelled = await Task.detached {
        let g = sample(3), original = g.nodes.map(\.bounds)
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            try await LayoutBuilder.create(g).useHierarchical().transform { $0.nodes[0].x = 999 }.applyAsync()
            return false
        } catch is CancellationError { return g.nodes.map(\.bounds) == original }
        catch { return false }
    }.value
    #expect(cancelled)
}

@Test func curveSmoothingIsBoundedAndKeepsEndpoints() {
    let g = sample(2), e = g.edges[0]
    e.path = [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100)]
    let router = CurveFittingEdgeRouter(); router.iterations = 100; router.routeEdges(g)
    #expect(e.path.count == 34)
    #expect(e.path.first == Point(x: 0, y: 0)); #expect(e.path.last == Point(x: 100, y: 100))
}

@Test func labelPlacementAcceptsSwiftPayloadAndKeepsMeasuredSize() {
    struct Payload: GraphLabelData { let label: String }
    let g = sample(2); g.nodes[1].x = 400
    let e = g.edges[0]; e.data = Payload(label: "calls"); e.path = [e.source.center, e.target.center]
    LabelPlacementAlgorithm().applyLabelPlacement(g)
    #expect(e.labelBounds.width == 50); #expect(e.labelBounds.height == 20)
    let size = e.labelBounds.size
    LabelLayoutAlgorithm().applyLabelLayout(g)
    #expect(e.labelBounds.size == size)
    #expect(e.data as? Payload != nil)
    #expect(e.labelBounds.x.isFinite && e.labelBounds.y.isFinite)
}

@Test func componentPackingTranslatesPathsWithoutReparenting() throws {
    let g = sample(6); g.edges.remove(at: 2)
    let parents = g.nodes.map(\.parent)
    try ComponentLayout(HierarchicalLayoutAlgorithm()).applyLayout(g)
    let first = enclosingBounds(Array(g.nodes.prefix(3))), second = enclosingBounds(Array(g.nodes.suffix(3)))
    #expect(!first.intersects(second)); #expect(g.nodes.map(\.parent) == parents)
    for e in g.edges { #expect(e.path.first == e.source.center); #expect(e.path.last == e.target.center) }
}

@Test func recursiveGroupCyclesThrowInsteadOfRecursingForever() throws {
    let g = sample(1), node = g.nodes[0]; node.isGroup = true; node.children = [node]
    #expect(throws: GraphError.cyclicGroupHierarchy) { try RecursiveGroupLayout(TreeLayoutAlgorithm()).applyLayout(g) }
}

@Test func barycenterHonorsExplicitAnchors() throws {
    let g = sample(3)
    g.nodes[0].center = Point(x: 0, y: 0); g.nodes[2].center = Point(x: 300, y: 100)
    g.nodes[0].metadata[GraphMetadataKeys.fixed] = true; g.nodes[2].metadata[GraphMetadataKeys.fixed] = true
    let anchors = [g.nodes[0].bounds, g.nodes[2].bounds]
    try BarycenterLayoutAlgorithm().applyLayout(g)
    #expect(g.nodes[1].center == Point(x: 150, y: 50))
    #expect([g.nodes[0].bounds, g.nodes[2].bounds] == anchors)
}

@Test func channelAllowsEndpointCellsAndSelectsCandidatePorts() {
    let g = sample(3), e = LayoutEdge(source: g.nodes[0], target: g.nodes[1]); g.edges = [e]
    g.nodes[0].bounds = Rect(width: 20, height: 20); g.nodes[1].bounds = Rect(x: 300, y: 0, width: 20, height: 20)
    g.nodes[2].bounds = Rect(x: -10, y: -10, width: 40, height: 40)
    let router = ChannelEdgeRouter(); router.routeEdges(g)
    #expect(router.unroutableEdges.isEmpty); #expect(e.path == [e.source.center, e.target.center])
    g.nodes[2].y = 400; e.sourcePortCandidates = [.top]; e.targetPortCandidates = [.bottom]
    router.routeEdges(g)
    #expect(router.unroutableEdges.isEmpty)
    #expect(e.path.first == Point(x: 10, y: -1)); #expect(e.path.last == Point(x: 310, y: 21))
}

@Test func channelCutsDoNotSplitAnEarlierWideRectangle() {
    let root = LayoutNode(id: "root", width: 400, height: 200)
    for (i, rect) in [Rect(width: 300, height: 20), Rect(x: 100, y: 40, width: 20, height: 20), Rect(x: 200, y: 80, width: 20, height: 20)].enumerated() {
        let n = LayoutNode(id: "\(i)", width: rect.width, height: rect.height); n.bounds = rect; root.children.append(n)
    }
    let calculator = ChannelGridCalculator(); calculator.buildChannels(root)
    let grid = calculator.getGrid(root)
    #expect(!grid.xChannels.contains(160))
    let graph = LayoutGraph(); graph.nodes = root.children; graph.root.children = root.children
    let bsp = BspGridCalculator(); bsp.buildTree(graph)
    #expect(!bsp.getGlobalGridSegments().isEmpty)
}

@Test func bundlingHandlesAntiparallelEdgesAndZeroSegments() {
    let g = sample(4); g.edges = []
    for (node, point) in zip(g.nodes, [Point(x: 0, y: 0), Point(x: 300, y: 0), Point(x: 300, y: 20), Point(x: 0, y: 20)]) { node.center = point }
    g.addEdge(LayoutEdge(source: g.nodes[0], target: g.nodes[1])); g.addEdge(LayoutEdge(source: g.nodes[2], target: g.nodes[3]))
    let router = EdgeBundlingRouter(); router.routeEdges(g)
    #expect(g.edges[0].path[5].y > 0); #expect(g.edges[1].path[5].y < 20)
    for e in g.edges { #expect(e.path.first == e.source.center); #expect(e.path.last == e.target.center) }
    router.segments = 0; router.routeEdges(g); #expect(g.edges.allSatisfy { $0.path.count == 2 })
}

@Test func noOpAlignmentPreservesLongEdgeBends() throws {
    let g = sample(3), e = LayoutEdge(source: g.nodes[0], target: g.nodes[2]); g.addEdge(e)
    try HierarchicalLayoutAlgorithm().applyLayout(g); let path = e.path
    try AlignmentLayoutAlgorithm().applyLayout(g); #expect(e.path == path)
}

@Test func onlyChannelRouterInterpretsCandidatePorts() {
    for router in [PolylineEdgeRouter() as any EdgeRouter, BspEdgeRouter(), OrthogonalGroupedEdgeRouter()] {
        let g = sample(2); g.nodes[0].bounds = Rect(width: 40, height: 40); g.nodes[1].bounds = Rect(x: 200, y: 0, width: 40, height: 40)
        let e = g.edges[0]
        router.routeEdges(g); let unconstrained = e.path
        e.sourcePortCandidates = [.top]; e.targetPortCandidates = [.bottom]
        router.routeEdges(g)
        #expect(e.path == unconstrained)
    }
}

@Test func barnesHutOpensCellsStraddlingRepulsionCutoff() {
    let points = [Point.zero] + (0..<100).map { Point(x: 490 + Double($0), y: Double($0 % 2)) }
    let tree = ForceQuadTree(theta: 100); tree.build(points)
    let force = tree.computeForce(nodeIndex: 0, position: .zero, repulsionSquared: 1000)
    let expected = points.dropFirst().filter { $0.length <= 500 }.reduce(Point.zero) { $0 - $1 * (1000 / $1.lengthSquared) }
    // Cells entirely within range may be approximated; a cutoff-crossing cell must be opened.
    #expect(force.x < 0); #expect(abs(force.x - expected.x) / abs(expected.x) < 0.001)
}

@Test func overlapRemovalHandlesNonAdjacentWideRectangles() throws {
    let g = sample(5)
    let rects = [Rect(width: 300, height: 50), Rect(x: 20, y: 100, width: 100, height: 50), Rect(x: 40, y: 20, width: 100, height: 120), Rect(x: 70, y: 80, width: 50, height: 50), Rect(x: 100, y: 0, width: 80, height: 150)]
    for (node, rect) in zip(g.nodes, rects) { node.bounds = rect }
    try RemoveOverlapsLayoutAlgorithm().applyLayout(g)
    for i in g.nodes.indices { for j in g.nodes.indices where i < j { #expect(!g.nodes[i].bounds.intersects(g.nodes[j].bounds)) } }
    let original = g.nodes.map(\.bounds); try RemoveOverlapsLayoutAlgorithm().applyLayout(g)
    #expect(g.nodes.map(\.bounds) == original)
}
