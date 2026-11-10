import Foundation

// The async counterpart drives the same `DirectedComponentRun` steps as `apply`, letting the hierarchy
// and geometry kernels suspend without blocking the executor.
extension DirectedLayoutOperation {
    func applyAsyncWorking(
        _ original: LayoutGraph,
        hierarchy: (LayoutGraph, DirectedHierarchy) async throws -> Void,
        measure: ([LayoutNode], [LayoutEdge]) async throws -> DirectedGeometry.Score,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> DirectedLayoutDiagnostics {
        if let constrained = constrainedConfiguration(for: original) {
            return try await DirectedLayoutOperation(configuration: constrained, cache: cache)
                .applyAsyncWorking(original, hierarchy: hierarchy, measure: measure)
        }
        guard let plan = try LayoutStageScope.run("Prepare", to: 0.05, { try prepare(original) }) else {
            return .init()
        }
        let slices = plan.componentSlices
        for (index, component) in plan.components.enumerated() {
            try Task.checkCancellation()
            try await LayoutStageScope.run(
                "Component \(index + 1)/\(plan.components.count)",
                from: slices[index].from,
                to: slices[index].to
            ) {
                let run = DirectedComponentRun(self, plan, component)
                for candidate in 0..<run.candidateCount {
                    try Task.checkCancellation()
                    let settled = try await LayoutStageScope.run(
                        "Candidate \(candidate + 1)/\(run.candidateCount)",
                        from: 0.8 * Double(candidate) / Double(run.candidateCount),
                        to: 0.8 * Double(candidate + 1) / Double(run.candidateCount)
                    ) {
                        if let placement = try run.place(candidate) {
                            try await LayoutStageScope.run("Hierarchy", to: 0.4) {
                                try await hierarchy(run.sub, placement)
                            }
                        }
                        run.placed()
                        return try await LayoutStageScope.run("Routing", from: 0.4) {
                            try run.routeIncumbent()
                            let first = try await measure(run.members, run.edges)
                            let score =
                                try run.routeCoordinated(after: first)
                                ? try await measure(run.members, run.edges) : first
                            return run.settle(score)
                        }
                    }
                    if settled { break }
                }
                try await LayoutStageScope.run("Refinement", from: 0.8) {
                    let candidates = run.refinementCandidates
                    for (position, candidate) in candidates.enumerated() {
                        LayoutStageScope.tick(position, of: candidates.count)
                        try run.refine(candidate)
                        run.keepRefined(try await measure(run.members, run.edges))
                    }
                }
                run.finishRefinement()
                try run.publish()
            }
        }
        LayoutStageScope.run("Pack", from: 0.9, to: 0.95) { pack(plan) }
        return try await LayoutStageScope.run("Finish", from: 0.95) {
            try finish(plan, try await measure(plan.nodes, plan.edges))
        }
    }
}
