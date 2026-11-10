import Foundation

extension LayoutBuilder {
    @discardableResult public func analyzePageRank(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout PageRankConfiguration) -> Void = { _ in }
    ) -> Self {
        var configuration = PageRankConfiguration()
        configure(&configuration)
        return useAsyncAlgorithm(
            AnalysisLayoutOperation(.pageRank, backend: backend, executor: executor, pageRank: configuration)
        )
    }

    @discardableResult public func analyzeClusters(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout ClusterAnalysisConfiguration) -> Void = { _ in }
    ) -> Self {
        var configuration = ClusterAnalysisConfiguration()
        configure(&configuration)
        return useAsyncAlgorithm(
            AnalysisLayoutOperation(.clusters, backend: backend, executor: executor, clusters: configuration)
        )
    }
}
