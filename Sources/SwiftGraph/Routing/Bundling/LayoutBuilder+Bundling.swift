import Foundation

extension LayoutBuilder {
    @discardableResult public func routeWithBundling(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout EdgeBundlingConfiguration) -> Void = { _ in }
    ) -> Self {
        var configuration = EdgeBundlingConfiguration()
        configure(&configuration)
        return useAsyncAlgorithm(
            EdgeBundlingOperation(backend: backend, executor: executor, configuration: configuration)
        )
    }
}
