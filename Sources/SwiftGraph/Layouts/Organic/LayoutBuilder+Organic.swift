import Foundation

extension LayoutBuilder {
    /// Opt-in execution backend; the existing useOrganic closure keeps its CPU behavior.
    @discardableResult public func useOrganic(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout OrganicLayoutConfiguration) -> Void = { _ in }
    ) -> Self {
        var configuration = OrganicLayoutConfiguration()
        configure(&configuration)
        return useAsyncAlgorithm(
            OrganicLayoutOperation(backend: backend, executor: executor, configuration: configuration)
        )
    }
}
