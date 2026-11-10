import Foundation

extension LayoutBuilder {
    @discardableResult public func useBasic(
        _ style: BasicLayoutStyle,
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }
    ) -> Self {
        var c = BasicLayoutConfiguration(style: style)
        configure(&c)
        return useAsyncAlgorithm(
            BasicLayoutOperation(style: style, backend: backend, executor: executor, configuration: c)
        )
    }

    @discardableResult public func useCircular(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useBasic(.circular, backend: backend, executor: executor, configure: configure) }

    @discardableResult public func useTabular(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useBasic(.tabular, backend: backend, executor: executor, configure: configure) }

    @discardableResult public func useOrthogonal(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useBasic(.orthogonal, backend: backend, executor: executor, configure: configure) }

    @discardableResult public func usePartitionGrid(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useBasic(.partitionGrid, backend: backend, executor: executor, configure: configure) }

    @discardableResult public func useKandinsky(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useBasic(.kandinsky, backend: backend, executor: executor, configure: configure) }

    @discardableResult public func useCompactDisk(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useBasic(.compactDisk, backend: backend, executor: executor, configure: configure) }

    @discardableResult public func useAlignment(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useBasic(.alignment, backend: backend, executor: executor, configure: configure) }

    @discardableResult public func useVerticalStack(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useBasic(.verticalStack, backend: backend, executor: executor, configure: configure) }

    @discardableResult public func useRemoveOverlaps(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }
    ) -> Self { useBasic(.removeOverlaps, backend: backend, executor: executor, configure: configure) }

    @discardableResult public func useFillArea(
        _ area: Rect,
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }
    ) -> Self {
        useBasic(.fillArea, backend: backend, executor: executor) { c in
            c.area = area
            configure(&c)
        }
    }

    @discardableResult public func useClearArea(
        _ area: Rect,
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout BasicLayoutConfiguration) -> Void = { _ in }
    ) -> Self {
        useBasic(.clearArea, backend: backend, executor: executor) { c in
            c.area = area
            configure(&c)
        }
    }
}
