/// An ordered, reusable layout pipeline. Configuration closures run when a step is added.
public final class LayoutBuilder {
    public let graph: LayoutGraph
    private var pipeline: [(LayoutGraph) async throws -> Void] = []
    public var pipelineLength: Int { pipeline.count }
    public init(graph: LayoutGraph) { self.graph = graph }
    public static func create(_ graph: LayoutGraph) -> LayoutBuilder { LayoutBuilder(graph: graph) }
    @discardableResult public func useAlgorithm(_ algorithm: any LayoutAlgorithm) -> Self {
        pipeline.append { graph in try algorithm.applyLayout(graph) }; return self
    }
    @discardableResult public func useAlgorithm<A: LayoutAlgorithm>(_ algorithm: A, configure: (A) -> Void) -> Self {
        configure(algorithm); return useAlgorithm(algorithm)
    }
    @discardableResult public func routeEdges(_ router: any EdgeRouter) -> Self {
        pipeline.append { graph in router.routeEdges(graph) }; return self
    }
    @discardableResult public func routeEdges<R: EdgeRouter>(_ router: R, configure: (R) -> Void) -> Self {
        configure(router); return routeEdges(router)
    }
    @discardableResult public func transform(_ operation: @escaping (LayoutGraph) throws -> Void) -> Self {
        pipeline.append { graph in try operation(graph) }; return self
    }
    @discardableResult public func transformAsync(_ operation: @escaping (LayoutGraph) async throws -> Void) -> Self {
        pipeline.append(operation); return self
    }
    public func applyAsync() async throws {
        for operation in pipeline { try Task.checkCancellation(); try await operation(graph); try Task.checkCancellation() }
    }
}

public extension LayoutBuilder {
    @discardableResult func useHierarchical(_ configure: (HierarchicalLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = HierarchicalLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useSeriesParallel(_ configure: (SeriesParallelLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = SeriesParallelLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useOrganic(_ configure: (OrganicLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = OrganicLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useBarycenter(_ configure: (BarycenterLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = BarycenterLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useTree(_ configure: (TreeLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = TreeLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useRadialTree(_ configure: (RadialTreeLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = RadialTreeLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useBalloon(_ configure: (BalloonLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = BalloonLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useRadial(_ configure: (RadialLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = RadialLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useRadialStar(_ configure: (RadialStarLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = RadialStarLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useOrthogonal(_ configure: (OrthogonalLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = OrthogonalLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func usePartitionGrid(_ configure: (PartitionGridLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = PartitionGridLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useTabular(_ configure: (TabularLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = TabularLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useKandinsky(_ configure: (KandinskyLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = KandinskyLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useCircular(_ configure: (CircularLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = CircularLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useSwimlane(_ configure: (SwimlaneLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = SwimlaneLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useTreeMap(_ configure: (TreeMapLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = TreeMapLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useCompactDisk(_ configure: (CompactDiskLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = CompactDiskLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useOrgChart(_ configure: (OrgChartLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = OrgChartLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useAlignment(_ configure: (AlignmentLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = AlignmentLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useGivenCoordinates(_ configure: (GivenCoordinatesLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = GivenCoordinatesLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useVerticalStack(_ configure: (VerticalStackLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = VerticalStackLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func removeOverlaps(_ configure: (RemoveOverlapsLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = RemoveOverlapsLayoutAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func analyzePageRank(_ configure: (PageRankAlgorithm) -> Void = { _ in }) -> Self {
        let value = PageRankAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func analyzeClusters(_ configure: (LabelPropagationClusteringAlgorithm) -> Void = { _ in }) -> Self {
        let value = LabelPropagationClusteringAlgorithm(); configure(value); return useAlgorithm(value)
    }
    @discardableResult func routePolyline(_ configure: (PolylineEdgeRouter) -> Void = { _ in }) -> Self {
        let value = PolylineEdgeRouter(); configure(value); return routeEdges(value)
    }
    @discardableResult func routeChannel(_ configure: (ChannelEdgeRouter) -> Void = { _ in }) -> Self {
        let value = ChannelEdgeRouter(); configure(value); return routeEdges(value)
    }
    @discardableResult func routeBus(_ configure: (BusEdgeRouter) -> Void = { _ in }) -> Self {
        let value = BusEdgeRouter(); configure(value); return routeEdges(value)
    }
    @discardableResult func routeOctilinear(_ configure: (OctilinearEdgeRouter) -> Void = { _ in }) -> Self {
        let value = OctilinearEdgeRouter(); configure(value); return routeEdges(value)
    }
    @discardableResult func routeWithBundling(_ configure: (EdgeBundlingRouter) -> Void = { _ in }) -> Self {
        let value = EdgeBundlingRouter(); configure(value); return routeEdges(value)
    }
    @discardableResult func routeParallelEdges(_ configure: (ParallelEdgeRouter) -> Void = { _ in }) -> Self {
        let value = ParallelEdgeRouter(); configure(value); return routeEdges(value)
    }
    @discardableResult func routeSelfLoops(_ configure: (SelfLoopRouter) -> Void = { _ in }) -> Self {
        let value = SelfLoopRouter(); configure(value); return routeEdges(value)
    }
    @discardableResult func routeCurveFitting(_ configure: (CurveFittingEdgeRouter) -> Void = { _ in }) -> Self {
        let value = CurveFittingEdgeRouter(); configure(value); return routeEdges(value)
    }
    @discardableResult func routeBsp(_ configure: (BspEdgeRouter) -> Void = { _ in }) -> Self {
        let value = BspEdgeRouter(); configure(value); return routeEdges(value)
    }
    @discardableResult func routeOrthogonalGrouped(_ configure: (OrthogonalGroupedEdgeRouter) -> Void = { _ in }) -> Self {
        let value = OrthogonalGroupedEdgeRouter(); configure(value); return routeEdges(value)
    }
}

public extension LayoutBuilder {
    @discardableResult func useMultiPage(coreLayout: (any LayoutAlgorithm)? = nil, configure: (MultiPageLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = MultiPageLayoutAlgorithm(coreLayout); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useFillArea(_ area: Rect, configure: (FillAreaLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = FillAreaLayoutAlgorithm(area); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useClearArea(_ area: Rect, configure: (ClearAreaLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = ClearAreaLayoutAlgorithm(area); configure(value); return useAlgorithm(value)
    }
    @discardableResult func useSubgraph(_ coreLayout: any LayoutAlgorithm, nodeFilter: @escaping (LayoutNode) -> Bool, configure: (SubgraphLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = SubgraphLayoutAlgorithm(coreLayout)
        transform { g in value.selectedNodeIds = Set(g.nodes.filter(nodeFilter).map(\.id)) }
        configure(value); return useAlgorithm(value)
    }
    @discardableResult func useStandardHierarchical(_ configure: (HierarchicalLayoutAlgorithm) -> Void = { _ in }) -> Self { useHierarchical(configure).routeSelfLoops() }
    @discardableResult func useStandardOrganic(_ configure: (OrganicLayoutAlgorithm) -> Void = { _ in }) -> Self { useOrganic(configure).routePolyline().routeSelfLoops() }
    @discardableResult func useEdgeBundlingPattern() -> Self { routePolyline().routeWithBundling() }
    @discardableResult func clipEdgeEndpoints() -> Self { transform(EdgeEndpointClipper.clipToNodeBounds) }
    @discardableResult func placeLabels(_ configure: (LabelPlacementAlgorithm) -> Void = { _ in }) -> Self {
        let value = LabelPlacementAlgorithm(); configure(value); return transform(value.applyLabelPlacement)
    }
}
