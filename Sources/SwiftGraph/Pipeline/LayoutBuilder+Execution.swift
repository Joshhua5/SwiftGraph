extension LayoutBuilder {
    @discardableResult public func useMultiPage(
        coreLayout: (any LayoutAlgorithm)? = nil,
        configure: (MultiPageLayoutAlgorithm) -> Void = { _ in }
    ) -> Self {
        let value = MultiPageLayoutAlgorithm(coreLayout)
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useFillArea(
        _ area: Rect,
        configure: (FillAreaLayoutAlgorithm) -> Void = { _ in }
    ) -> Self {
        let value = FillAreaLayoutAlgorithm(area)
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useClearArea(
        _ area: Rect,
        configure: (ClearAreaLayoutAlgorithm) -> Void = { _ in }
    ) -> Self {
        let value = ClearAreaLayoutAlgorithm(area)
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useSubgraph(
        _ coreLayout: any LayoutAlgorithm,
        nodeFilter: @escaping (LayoutNode) -> Bool,
        configure: (SubgraphLayoutAlgorithm) -> Void = { _ in }
    ) -> Self {
        let value = SubgraphLayoutAlgorithm(coreLayout)
        transform { g in value.selectedNodeIds = Set(g.nodes.filter(nodeFilter).map(\.id)) }
        configure(value)
        return useAlgorithm(value)
    }

    @discardableResult public func useStandardHierarchical(
        _ configure: (HierarchicalLayoutAlgorithm) -> Void = { _ in }
    ) -> Self { useHierarchical(configure).routeSelfLoops().clipEdgeEndpoints() }

    @discardableResult public func useStandardOrganic(_ configure: (OrganicLayoutAlgorithm) -> Void = { _ in }) -> Self
    { useOrganic(configure).routePolyline().routeSelfLoops().clipEdgeEndpoints() }

    @discardableResult public func useEdgeBundlingPattern() -> Self { routePolyline().routeWithBundling() }
    @discardableResult public func clipEdgeEndpoints() -> Self { transform(EdgeEndpointClipper.clipToNodeBounds) }
    @discardableResult public func placeLabels(_ configure: (LabelPlacementAlgorithm) -> Void = { _ in }) -> Self {
        let value = LabelPlacementAlgorithm()
        configure(value)
        return transform(value.applyLabelPlacement)
    }
}
