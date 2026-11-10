extension LayoutBuilder {
    @discardableResult public func useHierarchical(
        _ configure: (HierarchicalLayoutAlgorithm) -> Void = { _ in }
    ) -> Self {
        let value = HierarchicalLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useSeriesParallel(
        _ configure: (SeriesParallelLayoutAlgorithm) -> Void = { _ in }
    ) -> Self {
        let value = SeriesParallelLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useOrganic(_ configure: (OrganicLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = OrganicLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useBarycenter(_ configure: (BarycenterLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = BarycenterLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useTree(_ configure: (TreeLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = TreeLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useRadialTree(_ configure: (RadialTreeLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = RadialTreeLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useBalloon(_ configure: (BalloonLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = BalloonLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useRadial(_ configure: (RadialLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = RadialLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useRadialStar(_ configure: (RadialStarLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = RadialStarLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useOrthogonal(_ configure: (OrthogonalLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = OrthogonalLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func usePartitionGrid(
        _ configure: (PartitionGridLayoutAlgorithm) -> Void = { _ in }
    ) -> Self {
        let value = PartitionGridLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useTabular(_ configure: (TabularLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = TabularLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useKandinsky(_ configure: (KandinskyLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = KandinskyLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useCircular(_ configure: (CircularLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = CircularLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useSwimlane(_ configure: (SwimlaneLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = SwimlaneLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useTreeMap(_ configure: (TreeMapLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = TreeMapLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useCompactDisk(_ configure: (CompactDiskLayoutAlgorithm) -> Void = { _ in }) -> Self
    {
        let value = CompactDiskLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useOrgChart(_ configure: (OrgChartLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = OrgChartLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useAlignment(_ configure: (AlignmentLayoutAlgorithm) -> Void = { _ in }) -> Self {
        let value = AlignmentLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useGivenCoordinates(
        _ configure: (GivenCoordinatesLayoutAlgorithm) -> Void = { _ in }
    ) -> Self {
        let value = GivenCoordinatesLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useVerticalStack(
        _ configure: (VerticalStackLayoutAlgorithm) -> Void = { _ in }
    ) -> Self {
        let value = VerticalStackLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func removeOverlaps(
        _ configure: (RemoveOverlapsLayoutAlgorithm) -> Void = { _ in }
    ) -> Self {
        let value = RemoveOverlapsLayoutAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func analyzePageRank(_ configure: (PageRankAlgorithm) -> Void = { _ in }) -> Self {
        let value = PageRankAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func analyzeClusters(
        _ configure: (LabelPropagationClusteringAlgorithm) -> Void = { _ in }
    ) -> Self {
        let value = LabelPropagationClusteringAlgorithm()
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func routePolyline(_ configure: (PolylineEdgeRouter) -> Void = { _ in }) -> Self {
        let value = PolylineEdgeRouter()
        configure(value)
        return routeEdges(value)
    }

    @discardableResult public func routeChannel(_ configure: (ChannelEdgeRouter) -> Void = { _ in }) -> Self {
        let value = ChannelEdgeRouter()
        configure(value)
        return routeEdges(value)
    }

    @discardableResult public func routeBus(_ configure: (BusEdgeRouter) -> Void = { _ in }) -> Self {
        let value = BusEdgeRouter()
        configure(value)
        return routeEdges(value)
    }

    @discardableResult public func routeOctilinear(_ configure: (OctilinearEdgeRouter) -> Void = { _ in }) -> Self {
        let value = OctilinearEdgeRouter()
        configure(value)
        return routeEdges(value)
    }

    @discardableResult public func routeWithBundling(_ configure: (EdgeBundlingRouter) -> Void = { _ in }) -> Self {
        let value = EdgeBundlingRouter()
        configure(value)
        return routeEdges(value)
    }

    @discardableResult public func routeParallelEdges(_ configure: (ParallelEdgeRouter) -> Void = { _ in }) -> Self {
        let value = ParallelEdgeRouter()
        configure(value)
        return routeEdges(value)
    }

    @discardableResult public func separateEdges(_ configure: (EdgeSeparator) -> Void = { _ in }) -> Self {
        let value = EdgeSeparator()
        configure(value)
        return routeEdges(value)
    }

    @discardableResult public func routeSelfLoops(_ configure: (SelfLoopRouter) -> Void = { _ in }) -> Self {
        let value = SelfLoopRouter()
        configure(value)
        return routeEdges(value)
    }

    @discardableResult public func distributePorts(_ configure: (PortDistributor) -> Void = { _ in }) -> Self {
        let value = PortDistributor()
        configure(value)
        return routeEdges(value)
    }

    @discardableResult public func routeCurveFitting(_ configure: (CurveFittingEdgeRouter) -> Void = { _ in }) -> Self {
        let value = CurveFittingEdgeRouter()
        configure(value)
        return routeEdges(value)
    }

    @discardableResult public func routeBsp(_ configure: (BspEdgeRouter) -> Void = { _ in }) -> Self {
        let value = BspEdgeRouter()
        configure(value)
        return routeEdges(value)
    }

    @discardableResult public func routeOrthogonalGrouped(
        _ configure: (OrthogonalGroupedEdgeRouter) -> Void = { _ in }
    ) -> Self {
        let value = OrthogonalGroupedEdgeRouter()
        configure(value)
        return routeEdges(value)
    }
}
