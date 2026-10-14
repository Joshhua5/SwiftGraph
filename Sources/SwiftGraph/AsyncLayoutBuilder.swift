public extension LayoutBuilder {
    @discardableResult func useStandardOrganic(backend: LayoutBackend, executor: LayoutExecutor = .shared,
                                               configure: (inout OrganicLayoutConfiguration) -> Void = { _ in }) -> Self {
        useOrganic(backend: backend, executor: executor, configure: configure)
            .routePolyline(backend: backend, executor: executor).routeSelfLoops(backend: backend, executor: executor)
    }
    @discardableResult func useEdgeBundlingPattern(backend: LayoutBackend, executor: LayoutExecutor = .shared) -> Self {
        routePolyline(backend: backend, executor: executor).routeWithBundling(backend: backend, executor: executor)
    }
    @discardableResult func wrapWithComponentHandling(_ core: any AsyncLayoutAlgorithm, componentSpacing: Float = 20,
                                                       preferredAspectRatio: Float = 1) -> Self {
        let operation = ComponentLayoutOperation(core)
        operation.componentSpacing = componentSpacing; operation.preferredAspectRatio = preferredAspectRatio
        return useAsyncAlgorithm(operation)
    }
    @_disfavoredOverload
    @discardableResult func wrapWithRecursiveGroups(_ core: any AsyncLayoutAlgorithm,
        configure: (RecursiveGroupLayoutOperation) -> Void = { _ in }) -> Self {
        let operation = RecursiveGroupLayoutOperation(core); configure(operation); return useAsyncAlgorithm(operation)
    }
    @_disfavoredOverload
    @discardableResult func wrapWithFullComposition(_ core: any AsyncLayoutAlgorithm, componentSpacing: Float = 20,
        configure: (RecursiveGroupLayoutOperation) -> Void = { _ in }) -> Self {
        let operation = ComponentLayoutOperation(core); operation.componentSpacing = componentSpacing
        let groups = RecursiveGroupLayoutOperation(operation); configure(groups); return useAsyncAlgorithm(groups)
    }
    @discardableResult func useMultiPage(coreLayout: any AsyncLayoutAlgorithm,
                                        configure: (MultiPageLayoutOperation) -> Void = { _ in }) -> Self {
        let operation = MultiPageLayoutOperation(coreLayout); configure(operation); return useAsyncAlgorithm(operation)
    }
    @discardableResult func useSubgraph(_ core: any AsyncLayoutAlgorithm, nodeFilter: @escaping (LayoutNode) -> Bool,
                                       configure: (SubgraphLayoutOperation) -> Void = { _ in }) -> Self {
        let operation = SubgraphLayoutOperation(core)
        transform { graph in operation.selectedNodeIds = Set(graph.nodes.filter(nodeFilter).map(\.id)) }
        configure(operation); return useAsyncAlgorithm(operation)
    }
    @discardableResult func useSwimlane(subLayout: any AsyncLayoutAlgorithm,
                                       configure: (SwimlaneLayoutOperation) -> Void = { _ in }) -> Self {
        let operation = SwimlaneLayoutOperation(); operation.subLayout = subLayout; configure(operation)
        return useAsyncAlgorithm(operation)
    }
}

public extension LayoutBuilder {
    @discardableResult func removeOverlaps(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }) -> Self {
        useRemoveOverlaps(backend: backend, executor: executor, configure: configure)
    }
    @discardableResult func useMultiPage(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        coreLayout: (any AsyncLayoutAlgorithm)? = nil, configure: (MultiPageLayoutOperation) -> Void = { _ in }) -> Self {
        let operation = MultiPageLayoutOperation(coreLayout, backend: backend, executor: executor)
        configure(operation); return useAsyncAlgorithm(operation)
    }
    @discardableResult func useSwimlane(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        subLayout: (any AsyncLayoutAlgorithm)? = nil, configure: (SwimlaneLayoutOperation) -> Void = { _ in }) -> Self {
        let operation = SwimlaneLayoutOperation(backend: backend, executor: executor)
        operation.subLayout = subLayout; configure(operation); return useAsyncAlgorithm(operation)
    }
    @discardableResult func useSubgraph(_ core: any AsyncLayoutAlgorithm, backend: LayoutBackend,
        executor: LayoutExecutor = .shared, nodeFilter: @escaping (LayoutNode) -> Bool,
        configure: (SubgraphLayoutOperation) -> Void = { _ in }) -> Self {
        let operation = SubgraphLayoutOperation(core, backend: backend, executor: executor)
        transform { graph in operation.selectedNodeIds = Set(graph.nodes.filter(nodeFilter).map(\.id)) }
        configure(operation); return useAsyncAlgorithm(operation)
    }
    @discardableResult func wrapWithRecursiveGroups(_ core: any AsyncLayoutAlgorithm, backend: LayoutBackend,
        executor: LayoutExecutor = .shared, configure: (RecursiveGroupLayoutOperation) -> Void = { _ in }) -> Self {
        let operation = RecursiveGroupLayoutOperation(core, backend: backend, executor: executor)
        configure(operation); return useAsyncAlgorithm(operation)
    }
    @discardableResult func wrapWithFullComposition(_ core: any AsyncLayoutAlgorithm, backend: LayoutBackend,
        executor: LayoutExecutor = .shared, componentSpacing: Float = 20,
        configure: (RecursiveGroupLayoutOperation) -> Void = { _ in }) -> Self {
        let operation = ComponentLayoutOperation(core, backend: backend, executor: executor); operation.componentSpacing = componentSpacing
        let groups = RecursiveGroupLayoutOperation(operation, backend: backend, executor: executor)
        configure(groups); return useAsyncAlgorithm(groups)
    }
    @discardableResult func applyImportanceBased(_ core: any AsyncLayoutAlgorithm, backend: LayoutBackend,
        executor: LayoutExecutor = .shared) -> Self {
        let operation = ImportanceLayoutOperation(core, backend: backend, executor: executor)
        return useAsyncAlgorithm(operation).routePolyline(backend: backend, executor: executor)
            .routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
    @discardableResult func applyClusterBased(_ core: any AsyncLayoutAlgorithm, backend: LayoutBackend,
        executor: LayoutExecutor = .shared) -> Self {
        let operation = ClusterLayoutOperation(core, backend: backend, executor: executor)
        return useAsyncAlgorithm(operation).routePolyline(backend: backend, executor: executor)
            .routeSelfLoops(backend: backend, executor: executor).clipEdgeEndpoints(backend: backend, executor: executor).distributePorts(backend: backend, executor: executor)
    }
}

public extension LayoutBuilder {
    @discardableResult func wrapWithComponentHandling(_ core: any AsyncLayoutAlgorithm, backend: LayoutBackend,
        executor: LayoutExecutor = .shared, componentSpacing: Float = 20, preferredAspectRatio: Float = 1) -> Self {
        let operation = ComponentLayoutOperation(core, backend: backend, executor: executor)
        operation.componentSpacing = componentSpacing; operation.preferredAspectRatio = preferredAspectRatio
        return useAsyncAlgorithm(operation)
    }
}
