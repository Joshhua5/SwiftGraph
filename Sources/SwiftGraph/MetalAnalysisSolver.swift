import Foundation
#if canImport(Metal)
import Metal

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
        }
        let values = result(input, count: state.count)
        guard values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw OrganicLayoutError.metalFailure("Non-finite PageRank output") }
        return (values.map { Double($0.x) + Double($0.y) }, gpu)
    }
    func clustersAsync(_ state: AnalysisState,
                       isolation: isolated (any Actor)? = #isolation) async throws -> (labels: [Int], gpuSeconds: Double) {
        let vote = try pipeline(resource: "Analysis", function: "orderedClusterVotes")
        var resources: [any MTLBuffer] = []
        defer { recycle(resources) }
        resources.append(try buffer((0..<state.count).map(UInt32.init)))
        resources.append(try buffer(state.neighborOffsets)); resources.append(try buffer(state.neighbors))
        resources.append(try buffer((0..<state.count).map(UInt32.init)))
        resources.append(try buffer(Array(repeating: UInt32(0), count: state.count))) // label counts
        resources.append(try buffer(Array(repeating: UInt32(0), count: state.count))) // first-seen label order
        resources.append(try buffer([UInt32(0)]))
        var order = Array(0..<state.count), random = SeededRandom(), gpu = 0.0
        struct Parameters { var start: UInt32; var end: UInt32; var count: UInt32; var padding: UInt32 = 0 }
        // Each kernel visits nodes serially. Snapshot/Jacobi updates would change clustering.
        // Bounded chunks are separate commands so cancellation can drain before the next chunk.
        let maximumDegree = zip(state.neighborOffsets, state.neighborOffsets.dropFirst()).map { Int($1 - $0) }.max() ?? 0
        let batch = max(1, min(128, 262_144 / max(1, maximumDegree)))
        for _ in 0..<20 {
            try Task.checkCancellation(); shuffle(&order, random: &random)
            let shuffled = order.map(UInt32.init)
            shuffled.withUnsafeBytes { bytes in resources[3].contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
            resources[6].contents().storeBytes(of: UInt32(0), as: UInt32.self)
            for start in stride(from: 0, to: state.count, by: batch) {
                try Task.checkCancellation()
                guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                    throw OrganicLayoutError.metalFailure("Could not encode ordered cluster votes")
                }
                command.label = "Ordered label propagation votes"
                encoder.setComputePipelineState(vote)
                for (i, resource) in resources.enumerated() { encoder.setBuffer(resource, offset: 0, index: i) }
                var p = Parameters(start: UInt32(start), end: UInt32(min(state.count, start + batch)), count: UInt32(state.count))
                encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 7)
                encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)); encoder.endEncoding()
                gpu += try await submit(command)
            }
            if resources[6].contents().load(as: UInt32.self) == 0 { break }
        }
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
