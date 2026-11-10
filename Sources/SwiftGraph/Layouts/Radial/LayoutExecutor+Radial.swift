import Foundation

extension LayoutExecutor {
    func radial(
        _ snapshot: GeometrySnapshot,
        style: RadialLayoutStyle,
        configuration: RadialLayoutConfiguration,
        backend: LayoutBackend
    ) async throws -> RadialResult {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        try configuration.validate()
        try options.validate()
        let graph = snapshot.makeGraph()
        let plan = try LayoutStageScope.run("Plan", to: 0.2) { try RadialPlacementPlan(graph, style: style) }
        let clearance = LayoutStageScope.begin("Clearance", from: 0.2, to: 0.7)
        var chosen = backend
        var reason: LayoutFallbackReason?
        var gpu: Double?
        var device: String?
        if plan.pairCount == 0 {
            chosen = .cpu
            reason = .noWork
        } else if backend == .automatic {
            if plan.pairCount < Double(options.minimumRadialPairCount) {
                chosen = .cpu
                reason = .belowThreshold
            } else if !metalEnabled || !Self.isMetalAvailable {
                chosen = .cpu
                reason = .metalUnavailable
            } else {
                chosen = .metal
            }
        }
        var clearances: [Float] = []
        if chosen == .metal {
            do {
                let state = try RadialClearanceState(plan.rings, tolerance: options.maximumCoordinateError)
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                let solver = try metalSolver()
                let result = try await solver.radialClearanceAsync(state)
                gpu = result.gpuSeconds
                device = solver.deviceName
                var offset = 0
                for ring in plan.rings {
                    var radius: Float = 0.0
                    for i in ring.indices.indices {
                        let j = Int(result.partners[offset + i]) - offset
                        guard j >= i, j < ring.indices.count else {
                            throw OrganicLayoutError.metalFailure("Invalid radial pair index")
                        }
                        if j != i { radius = max(radius, ring.clearance(i, j)) }
                    }
                    clearances.append(radius)
                    offset += ring.indices.count
                }
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu
                reason = .precisionLimit
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu
                reason = .metalUnavailable
            }
        }
        if chosen == .cpu {
            clearances = try plan.rings.enumerated()
                .map { index, ring in
                    clearance.tick(index, of: plan.rings.count)
                    return try ring.cpuClearance()
                }
        }
        clearance.end()
        try LayoutStageScope.run("Apply", from: 0.7) {
            try plan.apply(clearances, to: graph, spacing: configuration.spacing)
        }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).seconds
        return RadialResult(
            bounds: graph.nodes.map(\.bounds),
            routeEdges: style == .tree || !plan.components.isEmpty,
            metrics: LayoutExecutionMetrics(
                requestedBackend: backend,
                backend: chosen,
                fallbackReason: reason,
                nodeCount: snapshot.nodes.count,
                iterations: plan.pairCount == 0 ? 0 : 1,
                computeSeconds: elapsed,
                totalSeconds: elapsed,
                gpuSeconds: gpu,
                deviceName: device,
                cpuStages: chosen == .metal
                    ? [
                        "traversal and ring planning", "Double radius reconstruction and packing",
                        "obstacle route repair",
                    ] : ["radial placement and routing"],
                metalStages: chosen == .metal ? ["ring clearance pair selection"] : []
            )
        )
    }
}

struct RadialClearanceState: Sendable {
    /// High/low angle splitting preserves narrow tree sectors and the circular seam.
    var angles: [SIMD2<Float>] = []
    var diameters: [Float] = []
    var ends: [UInt32] = []
    var maximumRingSize = 0

    init(_ rings: [RadialRing], tolerance: Float) throws {
        for ring in rings {
            try Task.checkCancellation()
            let end = angles.count + ring.indices.count
            guard end < Int(UInt32.max) else { throw LayoutExecutionError.invalidInput("Too many radial nodes") }
            let chord = ring.minimumChord
            let bound = (Double(ring.diameters.max() ?? 0) + 20) / chord
            // A conservative Float arithmetic allowance for ranking candidate pairs.
            guard bound.isFinite, Float(bound).isFinite, bound * (1e-6 + 4e-14 / chord) <= Double(tolerance),
                ring.diameters.allSatisfy(\.isFinite)
            else { throw LayoutExecutionError.precisionLimit }
            angles.append(
                contentsOf: ring.angles.map { angle in
                    let high = Float(angle)
                    return SIMD2(high, Float(angle - Double(high)))
                }
            )
            diameters.append(contentsOf: ring.diameters)
            ends.append(contentsOf: repeatElement(UInt32(end), count: ring.indices.count))
            maximumRingSize = max(maximumRingSize, ring.indices.count)
        }
    }
}
