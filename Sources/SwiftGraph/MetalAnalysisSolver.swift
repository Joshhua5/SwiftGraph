import Foundation
#if canImport(Metal)
import Metal

/// Lets a command be committed now and awaited later, so several commands can be in flight.
/// Waiting deliberately ignores task cancellation (unlike `AsyncStream`), so callers can
/// always drain committed work before recycling the buffers it uses.
final class CommandCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var waiter: CheckedContinuation<Void, Never>?
    /// Must be created before the command is committed.
    init(_ command: any MTLCommandBuffer) {
        command.addCompletedHandler { [self] _ in
            lock.lock(); completed = true; let resumed = waiter; waiter = nil; lock.unlock()
            resumed?.resume()
        }
    }
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if completed { lock.unlock(); continuation.resume() } else { waiter = continuation; lock.unlock() }
        }
    }
}

private func splitAnalysisDouble(_ value: Double) -> SIMD2<Float> {
    let high = Float(value)
    return SIMD2(high, Float(value - Double(high)))
}
extension MetalForceSolver {
    func pageRankAsync(_ state: AnalysisState, configuration: PageRankConfiguration, batchSize: Int,
                       isolation: isolated (any Actor)? = #isolation) async throws -> (ranks: [Double], gpuSeconds: Double) {
        let errorBound = state.pageRankErrorBound(iterations: configuration.iterations)
        guard errorBound <= configuration.maximumRankError, state.count <= 16_777_216,
              state.degree.allSatisfy({ $0 <= 16_777_216 }) else { throw LayoutExecutionError.precisionLimit }
        let reduction = try pipeline(resource: "Analysis", function: "pageRankDangling")
        let step = try pipeline(resource: "Analysis", function: "pageRankStep")
        var resources: [any MTLBuffer] = []
        defer { recycle(resources) }
        resources.append(try buffer(Array(repeating: splitAnalysisDouble(1 / Double(state.count)), count: state.count)))
        resources.append(try buffer(Array(repeating: SIMD2<Float>.zero, count: state.count)))
        resources.append(try buffer(state.degree)); resources.append(try buffer(state.incomingOffsets)); resources.append(try buffer(state.incoming))
        resources.append(try buffer([SIMD2<Float>.zero]))
        var input = resources[0], output = resources[1]
        struct Parameters { var count: UInt32; var padding: UInt32 = 0; var base: SIMD2<Float>; var damping: SIMD2<Float> }
        var p = Parameters(count: UInt32(state.count), base: splitAnalysisDouble((1 - configuration.dampingFactor) / Double(state.count)), damping: splitAnalysisDouble(configuration.dampingFactor))
        var gpu = 0.0
        let batch = min(max(1, batchSize), max(1, 1_048_576 / max(1, state.incoming.count + state.count)))
        for start in stride(from: 0, to: configuration.iterations, by: batch) {
            try Task.checkCancellation()
            guard let command = queue.makeCommandBuffer() else { throw OrganicLayoutError.metalFailure("Could not create PageRank command") }
            command.label = "Double-single PageRank iterations"
            for _ in start..<min(configuration.iterations, start + batch) {
                guard let a = command.makeComputeCommandEncoder() else { throw OrganicLayoutError.metalFailure("Could not encode dangling reduction") }
                a.setComputePipelineState(reduction)
                a.setBuffer(input, offset: 0, index: 0); a.setBuffer(resources[2], offset: 0, index: 1); a.setBuffer(resources[5], offset: 0, index: 2)
                a.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 3)
                a.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)); a.endEncoding()
                guard let b = command.makeComputeCommandEncoder() else { throw OrganicLayoutError.metalFailure("Could not encode PageRank step") }
                b.setComputePipelineState(step)
                for (i, resource) in [input, output, resources[2], resources[3], resources[4], resources[5]].enumerated() { b.setBuffer(resource, offset: 0, index: i) }
                b.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 6)
                let width = min(128, step.maxTotalThreadsPerThreadgroup)
                b.dispatchThreadgroups(MTLSize(width: (state.count + width - 1) / width, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)); b.endEncoding()
                swap(&input, &output)
            }
            gpu += try await submit(command)
            LayoutStageScope.tick(start + batch, of: configuration.iterations)
        }
        let values = result(input, count: state.count)
        guard values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw OrganicLayoutError.metalFailure("Non-finite PageRank output") }
        return (values.map { Double($0.x) + Double($0.y) }, gpu)
    }
    func clustersAsync(_ state: AnalysisState,
                       isolation: isolated (any Actor)? = #isolation) async throws -> (labels: [Int], gpuSeconds: Double) {
        let vote = try pipeline(resource: "Analysis", function: "orderedClusterVotes")
        let rounds = 20
        // The seeded shuffle never reads labels, so every round's visit order is known before
        // any GPU work. Uploading them together removes the per-round host step.
        var order = Array(0..<state.count), random = SeededRandom(), orders: [UInt32] = []
        orders.reserveCapacity(rounds * state.count)
        for _ in 0..<rounds { shuffle(&order, random: &random); orders.append(contentsOf: order.lazy.map(UInt32.init)) }
        var resources: [any MTLBuffer] = []
        defer { recycle(resources) }
        resources.append(try buffer((0..<state.count).map(UInt32.init)))
        resources.append(try buffer(state.neighborOffsets)); resources.append(try buffer(state.neighbors))
        resources.append(try buffer(orders))
        resources.append(try buffer(Array(repeating: UInt32(0), count: state.count))) // label counts
        resources.append(try buffer(Array(repeating: UInt32(0), count: state.count))) // first-seen label order
        resources.append(try buffer(Array(repeating: UInt32(0), count: rounds)))      // per-round changed flags
        let changed = resources[6].contents().bindMemory(to: UInt32.self, capacity: rounds)
        struct Parameters { var start: UInt32; var end: UInt32; var count: UInt32; var round: UInt32 }
        struct Step { var round: Int; var start: Int; var end: Int }
        // Each kernel visits nodes serially. Snapshot/Jacobi updates would change clustering.
        // Dispatches keep their previous bounded size; a command now carries a work budget of
        // many dispatches so the host is not woken once per chunk.
        let maximumDegree = zip(state.neighborOffsets, state.neighborOffsets.dropFirst()).map { Int($1 - $0) }.max() ?? 0
        let batch = max(1, min(128, 262_144 / max(1, maximumDegree)))
        let dispatchesPerCommand = max(1, 16 * 262_144 / max(1, batch * max(1, maximumDegree)))
        var steps: [Step] = []
        for round in 0..<rounds {
            for start in stride(from: 0, to: state.count, by: batch) { steps.append(Step(round: round, start: start, end: min(state.count, start + batch))) }
        }
        var inFlight: [(command: any MTLCommandBuffer, completion: CommandCompletion, last: Step)] = []
        var gpu = 0.0, next = 0, converged = false
        // The host stops encoding once a fully completed round changed nothing. Commands
        // already in flight are harmless: the kernel's own flag check makes them no-ops.
        func awaitOldest() async throws {
            let oldest = inFlight.removeFirst()
            await oldest.completion.wait()
            gpu += try check(oldest.command)
            let completedRound = oldest.last.end == state.count ? oldest.last.round : oldest.last.round - 1
            if completedRound >= 0 {
                LayoutStageScope.tick(completedRound + 1, of: rounds)
                if changed[completedRound] == 0 { converged = true }
            }
        }
        do {
            while next < steps.count && !converged {
                try Task.checkCancellation()
                let slice = steps[next..<min(steps.count, next + dispatchesPerCommand)]
                next = slice.endIndex
                guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                    throw OrganicLayoutError.metalFailure("Could not encode ordered cluster votes")
                }
                command.label = "Ordered label propagation votes (\(slice.count) chunks)"
                encoder.setComputePipelineState(vote)
                for (i, resource) in resources.enumerated() { encoder.setBuffer(resource, offset: 0, index: i) }
                // Serial dispatch type: each chunk observes the previous chunk's label writes.
                for step in slice {
                    var p = Parameters(start: UInt32(step.start), end: UInt32(step.end), count: UInt32(state.count), round: UInt32(step.round))
                    encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 7)
                    encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
                }
                encoder.endEncoding()
                let completion = CommandCompletion(command)
                submittedBatches += 1; command.commit()
                inFlight.append((command, completion, slice.last!))
                // Two commands in flight: the next is encoded while the previous executes.
                if inFlight.count >= 2 { try await awaitOldest() }
            }
            while !inFlight.isEmpty { try await awaitOldest() }
        } catch {
            // Leased buffers are recycled by the deferred block only after the GPU is done with them.
            for pending in inFlight { await pending.completion.wait(); _ = try? check(pending.command) }
            throw error
        }
        try Task.checkCancellation()
        let pointer = resources[0].contents().bindMemory(to: UInt32.self, capacity: state.count)
        return (Array(UnsafeBufferPointer(start: pointer, count: state.count)).map(Int.init), gpu)
    }
}
#else
extension MetalForceSolver {
    func pageRankAsync(_ state: AnalysisState, configuration: PageRankConfiguration, batchSize: Int,
                       isolation: isolated (any Actor)? = #isolation) async throws -> (ranks: [Double], gpuSeconds: Double) { throw OrganicLayoutError.metalUnavailable }
    func clustersAsync(_ state: AnalysisState,
                       isolation: isolated (any Actor)? = #isolation) async throws -> (labels: [Int], gpuSeconds: Double) { throw OrganicLayoutError.metalUnavailable }
}
#endif
