import Foundation

extension LayoutBuilder {
    @discardableResult public func routeEdges(
        _ kind: RoutingKind,
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }
    ) -> Self {
        useAsyncAlgorithm(RoutingLayoutOperation(kind, backend: backend, executor: executor, configure: configure))
    }
}
