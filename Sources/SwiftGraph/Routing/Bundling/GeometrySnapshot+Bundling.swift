import Foundation

extension GeometrySnapshot {
    func bundler(_ configuration: EdgeBundlingConfiguration, paths: [[Point]]) -> EdgeBundler {
        EdgeBundler(
            configuration.settings,
            nodes: nodes.map(\.bounds),
            solid: nodes.map { !$0.isGroup },
            edges: edges.filter { $0.source != $0.target }
                .map {
                    .init(
                        source: $0.source,
                        target: $0.target,
                        from: nodes[$0.source].bounds.center,
                        to: nodes[$0.target].bounds.center,
                        path: $0.index < paths.count ? paths[$0.index] : []
                    )
                }
        )
    }

    func cpuBundle(_ configuration: EdgeBundlingConfiguration, paths: [[Point]]) throws -> [BundledPath] {
        var bundler = bundler(configuration, paths: paths)
        guard bundler.runCPU() else { throw CancellationError() }
        try Task.checkCancellation()
        return zip(edges.filter { $0.source != $0.target }, bundler.paths())
            .map { BundledPath(index: $0.index, points: $1) }
    }

    /// The first cycle's kernel input, after the precision and size checks Metal needs before any submission.
    func prepareBundling(
        _ configuration: EdgeBundlingConfiguration,
        paths: [[Point]] = [],
        tolerance: Float
    ) throws -> (state: BundlingState, bundler: EdgeBundler) {
        var bundler = bundler(configuration, paths: paths)
        guard !bundler.schedule.isEmpty else {
            throw LayoutExecutionError.invalidInput("Bundling has no iterations to run.")
        }
        guard bundler.edges.count < Int(UInt32.max),
            configuration.segments < Int(UInt32.max) / max(1, bundler.edges.count) - 1
        else {
            throw LayoutExecutionError.invalidInput("Too many bundle points for Metal indices.")
        }
        let extent = bundler.normalisedExtent
        guard extent.isFinite, extent.ulp * bundler.unit <= tolerance, configuration.k <= 1e6 else {
            throw LayoutExecutionError.precisionLimit
        }
        guard bundler.compatible.count < 8_388_608 else {
            throw LayoutExecutionError.invalidInput("Metal bundling compatibility exceeds the 64 MiB limit.")
        }
        return (bundler.state(cycle: 0), bundler)
    }
}
