import Foundation

/// Experimental Metal acceleration of Waring's organic force model.
///
/// One instance and its mutable graph must be confined to a single caller. Construction compiles the
/// Metal kernel once. Execution is synchronous; run it off the UI actor. Cancellation is checked at
/// every CPU iteration and between bounded Metal batches. The graph is only updated after success.
public final class AcceleratedOrganicLayoutAlgorithm: LayoutAlgorithm {
    public let backend: OrganicBackend
    public var scope: OrganicScope = .all
    public var iterations = 100
    public var initialTemperature: Float = 100
    public var repulsionForce: Float = 2_000
    public var attractionForce: Float = 0.05
    public var barnesHutTheta: Float = 0.8
    public var metalBatchSize = 8
    public private(set) var lastMetrics: OrganicLayoutMetrics?
    private let metal: MetalForceSolver?

    public init(backend: OrganicBackend = .cpuBarnesHut) throws {
        self.backend = backend
        metal = backend == .metal ? try MetalForceSolver() : nil
    }

    public static var isMetalAvailable: Bool { MetalForceSolver.isAvailable }
    public var deviceName: String? { metal?.deviceName }

    public func applyLayout(_ graph: LayoutGraph) throws {
        lastMetrics = nil
        try Task.checkCancellation()
        guard iterations >= 0, initialTemperature.isFinite, initialTemperature >= 0,
            repulsionForce.isFinite, repulsionForce >= 0, attractionForce.isFinite, attractionForce >= 0,
            barnesHutTheta.isFinite, barnesHutTheta > 0, metalBatchSize > 0,
            repulsionForce <= sqrt(Float.greatestFiniteMagnitude)
        else {
            throw OrganicLayoutError.invalidConfiguration(
                "Forces and temperature must be finite and nonnegative; iterations nonnegative; theta and batch size positive."
            )
        }
        let start = ContinuousClock.now
        var state = try ForceState(graph, scope: scope, scatter: iterations > 0)
        var gpuTime: Double?
        if !state.positions.isEmpty && iterations > 0 {
            let parameters = ForceParameters(
                repulsionSquared: repulsionForce * repulsionForce,
                attraction: attractionForce
            )
            if let metal {
                let result = try metal.solve(
                    state,
                    iterations: iterations,
                    temperature: initialTemperature,
                    parameters: parameters,
                    batchSize: metalBatchSize
                )
                state.positions = result.positions
                gpuTime = result.gpuSeconds
            } else {
                for step in 0..<iterations {
                    try Task.checkCancellation()
                    LayoutStageScope.tick(step, of: iterations)
                    let temperature = initialTemperature * (1 - Float(step) / Float(iterations))
                    state.positions = try cpuStep(
                        state,
                        parameters: parameters,
                        temperature: temperature,
                        theta: backend == .cpuBarnesHut ? barnesHutTheta : nil
                    )
                }
            }
            guard state.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw OrganicLayoutError.invalidConfiguration("Force calculation overflowed Float coordinates.")
            }
            try Task.checkCancellation()
            let pinned = state.fixed.contains(1)
            let minX = pinned ? 0 : (state.positions.map(\.x).min() ?? 0)
            let minY = pinned ? 0 : (state.positions.map(\.y).min() ?? 0)
            // Never rewrite fixed nodes: preserve exact bits.
            for i in graph.nodes.indices where state.fixed[i] == 0 {
                graph.nodes[i].center = Point(x: state.positions[i].x - minX, y: state.positions[i].y - minY)
            }
        }
        let elapsed = start.duration(to: .now)
        lastMetrics = OrganicLayoutMetrics(
            backend: backend,
            nodeCount: graph.nodes.count,
            iterations: iterations,
            wallTimeSeconds: elapsed.seconds,
            gpuTimeSeconds: gpuTime
        )
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
