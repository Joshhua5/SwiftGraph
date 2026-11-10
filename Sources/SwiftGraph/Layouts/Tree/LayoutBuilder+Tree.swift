import Foundation

extension LayoutBuilder {
    @discardableResult public func useTreeLayout(
        _ style: TreeLayoutStyle,
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout TreeLayoutConfiguration) -> Void = { _ in }
    ) -> Self {
        var c = TreeLayoutConfiguration()
        configure(&c)
        return useAsyncAlgorithm(
            TreeLayoutOperation(style: style, backend: backend, executor: executor, configuration: c)
        )
    }

    @discardableResult public func useTree(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout TreeLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useTreeLayout(.tree, backend: backend, executor: executor, configure: configure) }

    @discardableResult public func useBalloon(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout TreeLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useTreeLayout(.balloon, backend: backend, executor: executor, configure: configure) }

    @discardableResult public func useOrgChart(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout TreeLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useTreeLayout(.orgChart, backend: backend, executor: executor, configure: configure) }

    @discardableResult public func useTreeMap(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout TreeLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useTreeLayout(.treeMap, backend: backend, executor: executor, configure: configure) }
}
