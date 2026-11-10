import Foundation

extension LayoutBuilder {
    @discardableResult public func useDirected(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        cache: DirectedLayoutCache? = nil,
        configure: (inout DirectedLayoutConfiguration) -> Void = { _ in }
    ) -> Self {
        var configuration = DirectedLayoutConfiguration()
        configure(&configuration)
        return useAsyncAlgorithm(
            DirectedLayoutAsyncOperation(
                backend: backend,
                executor: executor,
                configuration: configuration,
                cache: cache
            )
        )
    }
}
