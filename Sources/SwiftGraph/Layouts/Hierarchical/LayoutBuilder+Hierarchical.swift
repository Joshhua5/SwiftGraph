import Foundation

extension LayoutBuilder {
    @discardableResult public func useHierarchical(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout HierarchicalLayoutConfiguration) -> Void = { _ in }
    ) -> Self {
        var configuration = HierarchicalLayoutConfiguration()
        configure(&configuration)
        return useAsyncAlgorithm(
            HierarchicalLayoutOperation(backend: backend, executor: executor, configuration: configuration)
        )
    }

    @discardableResult public func useSeriesParallel(backend: LayoutBackend, executor: LayoutExecutor = .shared) -> Self
    {
        useAsyncAlgorithm(SeriesParallelLayoutOperation(backend: backend, executor: executor))
    }

    @discardableResult public func useStandardHierarchical(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout HierarchicalLayoutConfiguration) -> Void = { _ in }
    ) -> Self {
        useHierarchical(backend: backend, executor: executor, configure: configure)
            .routeSelfLoops(backend: backend, executor: executor)
    }
}
