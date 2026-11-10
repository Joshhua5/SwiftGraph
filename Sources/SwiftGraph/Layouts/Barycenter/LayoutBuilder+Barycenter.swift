import Foundation

extension LayoutBuilder {
    @discardableResult public func useBarycenter(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BarycenterLayoutConfiguration) -> Void = { _ in }
    ) -> Self {
        var configuration = BarycenterLayoutConfiguration()
        configure(&configuration)
        return useAsyncAlgorithm(
            BarycenterLayoutOperation(backend: backend, executor: executor, configuration: configuration)
        )
    }
}
