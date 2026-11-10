import Foundation

extension LayoutBuilder {
    @discardableResult public func useRadial(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout RadialLayoutConfiguration) -> Void = { _ in }
    ) -> Self {
        var configuration = RadialLayoutConfiguration()
        configure(&configuration)
        return useAsyncAlgorithm(
            RadialLayoutOperation(backend: backend, executor: executor, configuration: configuration)
        )
    }

    @discardableResult public func useRadialStar(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout RadialLayoutConfiguration) -> Void = { _ in }
    ) -> Self {
        var configuration = RadialLayoutConfiguration(spacing: 200)
        configure(&configuration)
        return useAsyncAlgorithm(
            RadialLayoutOperation(style: .star, backend: backend, executor: executor, configuration: configuration)
        )
    }

    @discardableResult public func useRadialTree(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout RadialLayoutConfiguration) -> Void = { _ in }
    ) -> Self {
        var configuration = RadialLayoutConfiguration()
        configure(&configuration)
        return useAsyncAlgorithm(
            RadialLayoutOperation(style: .tree, backend: backend, executor: executor, configuration: configuration)
        )
    }

    @discardableResult public func applyMindMap(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        layerDistance: Float = 100
    ) -> Self {
        let configuration = RadialLayoutConfiguration(spacing: layerDistance)
        let core = RadialLayoutOperation(
            style: .tree,
            backend: backend,
            executor: executor,
            configuration: configuration
        )
        return groupedPreset(core, routing: .polyline, backend: backend, executor: executor)
    }
}
