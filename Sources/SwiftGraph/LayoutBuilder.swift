/// An ordered, reusable layout pipeline. Configuration closures run when a step is added.
public final class LayoutBuilder {
    public let graph: LayoutGraph
    private var pipeline: [Step] = []
    private let executionReport = LayoutPipelineReport()
    /// Records completed backend-aware stages from the latest applyAsync call.
    /// On failure, records from earlier successful pipeline stages remain available.
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { executionReport.metrics }
    public var pipelineLength: Int { pipeline.count }
    public init(graph: LayoutGraph) { self.graph = graph }
    public static func create(_ graph: LayoutGraph) -> LayoutBuilder { LayoutBuilder(graph: graph) }
    @discardableResult public func useAlgorithm(_ algorithm: any LayoutAlgorithm) -> Self {
        append(layoutStageName(algorithm)) { [executionReport] graph in
            try await algorithm.applyLayoutAsync(graph)
            executionReport.metrics += (algorithm as? any LayoutExecutionReporting)?.lastExecutionMetrics ?? []
        }
    }
    @discardableResult public func useAsyncAlgorithm(_ algorithm: any AsyncLayoutAlgorithm) -> Self {
        append(layoutStageName(algorithm)) { [executionReport] graph in
            try await algorithm.applyLayoutAsync(graph)
            executionReport.metrics += (algorithm as? any LayoutExecutionReporting)?.lastExecutionMetrics ?? []
        }
    }
    @discardableResult public func useAlgorithm<A: LayoutAlgorithm>(_ algorithm: A, configure: (A) -> Void) -> Self {
        configure(algorithm); return useAlgorithm(algorithm)
    }
    @discardableResult public func routeEdges(_ router: any EdgeRouter) -> Self {
        append(layoutStageName(router)) { graph in router.routeEdges(graph) }
    }
    @discardableResult public func routeEdges<R: EdgeRouter>(_ router: R, configure: (R) -> Void) -> Self {
        configure(router); return routeEdges(router)
    }
    @discardableResult public func transform(_ operation: @escaping (LayoutGraph) throws -> Void) -> Self {
        append("Transform") { graph in try operation(graph) }
    }
    @discardableResult public func transformAsync(_ operation: @escaping (LayoutGraph) async throws -> Void) -> Self {
        append("Transform", operation)
    }
    /// Renames the most recently added step and sets its share of overall progress (default weight 1).
    @discardableResult public func stage(_ name: String? = nil, weight: Double = 1) -> Self {
        guard !pipeline.isEmpty else { return self }
        if let name { pipeline[pipeline.count - 1].name = name }
        pipeline[pipeline.count - 1].weight = max(0, weight); return self
    }
    public func applyAsync() async throws {
        executionReport.metrics = []
        for step in pipeline { try Task.checkCancellation(); try await step.run(graph); try Task.checkCancellation() }
    }
    /// Runs the pipeline, reporting named stages and overall completion to `progress`.
    /// The handler is called on background threads and must return quickly. Calling this from the main actor
    /// runs the layout there; UI code should prefer `layoutProgress()` or a `@concurrent` caller.
    public func applyAsync(progress: (@Sendable (LayoutProgress) -> Void)?) async throws {
        guard let progress else { return try await applyAsync() }
        try await applyAsync(sink: LayoutProgressSink(handler: progress))
    }
    func applyAsync(sink: LayoutProgressSink) async throws {
        executionReport.metrics = []
        let steps = pipeline, slices = LayoutStageScope.slices(steps.map(\.weight))
        try await withLayoutProgress(sink) {
            for (step, slice) in zip(steps, slices) {
                try Task.checkCancellation()
                try await LayoutStageScope.run(step.name, from: slice.from, to: slice.to) { try await step.run(graph) }
                try Task.checkCancellation()
            }
        }
    }
    /// Runs the pipeline off the calling actor and streams its progress. Ending iteration early, or cancelling
    /// the consuming task, cancels the layout. Do not read or mutate the builder or its graph until the stream ends.
    public func layoutProgress() -> AsyncThrowingStream<LayoutProgress, Error> {
        let builder = UncheckedBuilder(value: self)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // Detached so that a main-actor consumer does not run the layout on the main thread.
            let task = Task.detached(priority: Task.currentPriority) {
                do { try await builder.value.applyAsync { continuation.yield($0) }; continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func append(_ name: String, _ run: @escaping (LayoutGraph) async throws -> Void) -> Self {
        pipeline.append(Step(name: name, weight: 1, run: run)); return self
    }
    private struct Step {
        var name: String
        var weight: Double
        let run: (LayoutGraph) async throws -> Void
    }
}

private final class LayoutPipelineReport {
    var metrics: [LayoutExecutionMetrics] = []
}
/// The stream contract hands the builder to its detached task until the stream finishes.
private struct UncheckedBuilder: @unchecked Sendable { let value: LayoutBuilder }

/// A readable stage name from a type name, e.g. `HierarchicalLayoutOperation` → "Hierarchical".
func layoutStageName(_ value: Any) -> String {
    var name = String(describing: type(of: value))
    if let generic = name.firstIndex(of: "<") { name = String(name[..<generic]) }
    for suffix in ["LayoutAsyncOperation", "LayoutOperation", "LayoutAlgorithm", "EdgeRouter", "Operation", "Algorithm", "Router"]
    where name.hasSuffix(suffix) && name.count > suffix.count {
        name.removeLast(suffix.count); break
    }
    return value is any EdgeRouter ? "\(name) routing" : name
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
    @discardableResult func separateEdges(_ configure: (EdgeSeparator) -> Void = { _ in }) -> Self {
        let value = EdgeSeparator(); configure(value); return routeEdges(value)
    }
    @discardableResult func routeSelfLoops(_ configure: (SelfLoopRouter) -> Void = { _ in }) -> Self {
        let value = SelfLoopRouter(); configure(value); return routeEdges(value)
    }
    @discardableResult func distributePorts(_ configure: (PortDistributor) -> Void = { _ in }) -> Self {
        let value = PortDistributor(); configure(value); return routeEdges(value)
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
    @discardableResult func useStandardHierarchical(_ configure: (HierarchicalLayoutAlgorithm) -> Void = { _ in }) -> Self { useHierarchical(configure).routeSelfLoops().clipEdgeEndpoints() }
    @discardableResult func useStandardOrganic(_ configure: (OrganicLayoutAlgorithm) -> Void = { _ in }) -> Self { useOrganic(configure).routePolyline().routeSelfLoops().clipEdgeEndpoints() }
    @discardableResult func useEdgeBundlingPattern() -> Self { routePolyline().routeWithBundling() }
    @discardableResult func clipEdgeEndpoints() -> Self { transform(EdgeEndpointClipper.clipToNodeBounds) }
    @discardableResult func placeLabels(_ configure: (LabelPlacementAlgorithm) -> Void = { _ in }) -> Self {
        let value = LabelPlacementAlgorithm(); configure(value); return transform(value.applyLabelPlacement)
    }
}
