import Foundation
#if canImport(Metal)
import Metal

extension MetalForceSolver {
    func directedGeometryAsync(nodes: [LayoutNode], edges: [LayoutEdge], tolerance: Double,
                              isolation: isolated (any Actor)? = #isolation) async throws -> (score: DirectedGeometry.Score, gpuSeconds: Double) {
        try Task.checkCancellation()
        let compute = try pipeline(resource: "HierarchicalLayouts", function: "directedGeometry")
        let rawPoints = edges.flatMap(\.path)
        let rawBounds = nodes.flatMap { [Point(x: $0.bounds.left, y: $0.bounds.top), Point(x: $0.bounds.right, y: $0.bounds.bottom)] }
        guard rawPoints.count + rawBounds.count < Int(UInt32.max) else { throw LayoutExecutionError.invalidInput("Too many directed geometry coordinates") }
        // Equality and coordinate ordering have discrete CPU semantics even when
        // two distinct Double values collapse to the same high/low Float encoding.
        let allCoordinates = rawPoints + rawBounds
        guard allCoordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw OrganicLayoutError.metalFailure("Non-finite directed geometry")
        }
        let xValues = Array(Set(allCoordinates.map(\.x))).sorted(), yValues = Array(Set(allCoordinates.map(\.y))).sorted()
        let xIDs = Dictionary(uniqueKeysWithValues: xValues.enumerated().map { ($0.element, UInt32($0.offset)) })
        let yIDs = Dictionary(uniqueKeysWithValues: yValues.enumerated().map { ($0.element, UInt32($0.offset)) })
        func coordinateID(_ point: Point) -> SIMD2<UInt32> { SIMD2(xIDs[point.x]!, yIDs[point.y]!) }
        let extent = (rawPoints + rawBounds).reduce(0.0) { max($0, abs($1.x), abs($1.y)) }
        guard extent.isFinite, Float(extent).isFinite, extent * 1e-13 <= min(tolerance, DirectedGeometry.epsilon / 100) else {
            throw LayoutExecutionError.precisionLimit
        }
        func split(_ value: Point) -> SIMD4<Float> {
            let x = Float(value.x), y = Float(value.y)
            return SIMD4(x, Float(value.x - Double(x)), y, Float(value.y - Double(y)))
        }
        var offsets: [UInt32] = [0]
        for edge in edges {
            guard Int(offsets.last!) + edge.path.count < Int(UInt32.max) else { throw LayoutExecutionError.invalidInput("Too many directed route points") }
            offsets.append(offsets.last! + UInt32(edge.path.count))
        }
        var leased: [any MTLBuffer] = []
        defer { recycle(leased) }
        func lease<T>(_ values: [T]) throws -> any MTLBuffer { let value = try buffer(values); leased.append(value); return value }
        let points = try lease(rawPoints.map(split))
        let pointIDs = try lease(rawPoints.map(coordinateID)), boundIDs = try lease(rawBounds.map(coordinateID))
        // Each job is one constant-work node or segment pair. Even one very long
        // pair of routes is spread across bounded, cancellable GPU commands.
        let batch = 16_384
        let jobsBuffer = try lease(Array(repeating: SIMD4<UInt32>.zero, count: batch))
        let resultBuffer = try lease(Array(repeating: SIMD4<UInt32>.zero, count: batch))
        var score = DirectedGeometry.Score(), seconds = 0.0
        for edge in edges {
            if edge.path.count < 2 { score.missing += 1 }
            score.bends += max(0, edge.path.count - 2)
            score.length += DirectedGeometry.segments(edge.path).reduce(0) { $0 + $1.length }
        }
        let rectangle = DirectedGeometry.bounds(nodes: nodes, edges: edges); score.area = rectangle.width * rectangle.height
        var jobs: [SIMD4<UInt32>] = []
        var edgePairs: [SIMD2<UInt32>] = []
        var hits: [SIMD2<UInt32>: Set<SIMD2<UInt32>>] = [:]
        var sharing: Set<SIMD2<UInt32>> = []
        func flush() async throws {
            guard !jobs.isEmpty else { return }
            try Task.checkCancellation()
            jobs.withUnsafeBytes { bytes in jobsBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw OrganicLayoutError.metalFailure("Could not encode directed geometry scoring")
            }
            command.label = "Directed geometry segment-pair decisions"
            encoder.setComputePipelineState(compute)
            for (i, resource) in [points, jobsBuffer, resultBuffer, pointIDs, boundIDs].enumerated() { encoder.setBuffer(resource, offset: 0, index: i) }
            var count = UInt32(jobs.count); encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 5)
            let width = min(128, compute.maxTotalThreadsPerThreadgroup)
            encoder.dispatchThreadgroups(MTLSize(width: (jobs.count + width - 1) / width, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            encoder.endEncoding(); seconds += try await submit(command)
            let values = resultBuffer.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: jobs.count)
            for i in jobs.indices {
                if jobs[i].z == 0 { score.overlaps += Int(values[i].x) }
                else {
                    let pair = edgePairs[i]
                    if values[i].x & 1 != 0 { hits[pair, default: []].insert(SIMD2(values[i].y, values[i].z)) }
                    if values[i].x & 2 != 0 { sharing.insert(pair) }
                    // GPU jobs are read in submission order. Finalizing at the last
                    // segment pair bounds CPU reduction state as well as GPU storage.
                    if jobs[i].w != 0 {
                        score.crossings += hits.removeValue(forKey: pair)?.count ?? 0
                        if sharing.remove(pair) != nil { score.shared += 1 }
                    }
                }
            }
            jobs.removeAll(keepingCapacity: true)
            edgePairs.removeAll(keepingCapacity: true)
        }
        for i in nodes.indices {
            if i + 1 < nodes.count { for j in (i + 1)..<nodes.count {
                    jobs.append(SIMD4(UInt32(i), UInt32(j), 0, 0)); edgePairs.append(.zero)
                    if jobs.count == batch { try await flush() }
            } }
        }
        for i in edges.indices where offsets[i + 1] > offsets[i] + 1 {
            if i + 1 < edges.count { for j in (i + 1)..<edges.count where offsets[j + 1] > offsets[j] + 1 {
                let endA = Int(offsets[i + 1]) - 1, endB = Int(offsets[j + 1]) - 1
                for a in Int(offsets[i])..<endA { for b in Int(offsets[j])..<endB {
                    let last = a + 1 == endA && b + 1 == endB
                    jobs.append(SIMD4(UInt32(a), UInt32(b), 1, last ? 1 : 0)); edgePairs.append(SIMD2(UInt32(i), UInt32(j)))
                    if jobs.count == batch { try await flush() }
                } }
            } }
        }
        try await flush(); try Task.checkCancellation()
        return (score, seconds)
    }

    func hierarchyAsync(_ plan: HierarchyPlacementPlan, directed: Bool, retainBest: Bool,
                        isolation: isolated (any Actor)? = #isolation) async throws -> HierarchyPlacementOutput {
        try Task.checkCancellation()
        let orderPipeline = try pipeline(resource: "HierarchicalLayouts", function: "hierarchyOrder")
        let placementPipeline = try pipeline(resource: "HierarchicalLayouts", function: "hierarchyPlacement")
        let n = plan.widths.count
        func flatten(_ lists: [[Int]]) -> (offsets: [UInt32], values: [UInt32]) {
            var offsets: [UInt32] = [0], values: [UInt32] = []
            for list in lists { values.append(contentsOf: list.map(UInt32.init)); offsets.append(UInt32(values.count)) }
            return (offsets, values)
        }
        let ranks = flatten(plan.layers), ins = flatten(plan.incoming), outs = flatten(plan.outgoing)
        var leased: [any MTLBuffer] = []
        defer { recycle(leased) }
        func lease<T>(_ values: [T]) throws -> any MTLBuffer {
            let result = try buffer(values); leased.append(result); return result
        }
        let layers = try lease(ranks.values), rankOffsets = try lease(ranks.offsets)
        let inOffsets = try lease(ins.offsets), incoming = try lease(ins.values)
        let outOffsets = try lease(outs.offsets), outgoing = try lease(outs.values)
        let temporarySize = max(n + 1, plan.incoming.map(\.count).max() ?? 0, plan.outgoing.map(\.count).max() ?? 0)
        let orderScratch = try lease(Array(repeating: UInt32(0), count: 3 * n + temporarySize + 3))
        let widths = try lease(plan.widths.map { value -> SIMD2<Float> in
            let high = Float(value); return SIMD2(high, Float(value - Double(high)))
        })
        let coordinateScratch = try lease(Array(repeating: SIMD2<Float>.zero, count: 4 * n))
        let blockScratch = try lease(Array(repeating: UInt32(0), count: 2 * n))
        let ends = try lease(Array(repeating: UInt32(0), count: 3 * n))
        let mergeCounts = try lease(Array(repeating: UInt32(0), count: 3 * n))
        struct Parameters {
            var count: UInt32; var originalCount: UInt32; var rankCount: UInt32
            var directed: UInt32; var retainBest: UInt32; var separation: SIMD2<Float>
            var action: UInt32 = 0; var iteration: UInt32 = 0; var rank: UInt32 = 0; var temporarySize: UInt32
        }
        var parameters = Parameters(count: UInt32(n), originalCount: UInt32(plan.originalCount), rankCount: UInt32(plan.layers.count),
            directed: directed ? 1 : 0, retainBest: retainBest ? 1 : 0,
            separation: SIMD2(Float(plan.nodeSeparation), Float(plan.nodeSeparation - Double(Float(plan.nodeSeparation)))), temporarySize: UInt32(temporarySize))
        let orderResources = [layers, rankOffsets, inOffsets, incoming, outOffsets, outgoing, orderScratch]
        let placementResources = [layers, rankOffsets, inOffsets, incoming, outOffsets, outgoing, widths, coordinateScratch, blockScratch, ends]
        var seconds = 0.0
        func run(action: UInt32, iteration: Int = 0, rank: Int = 0) async throws {
            try Task.checkCancellation()
            parameters.action = action; parameters.iteration = UInt32(iteration); parameters.rank = UInt32(rank)
            let placement = action >= 5
            let computePipeline = placement ? placementPipeline : orderPipeline
            let resources = placement ? placementResources : orderResources
            let parameterIndex = placement ? 10 : 7
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw OrganicLayoutError.metalFailure("Could not encode hierarchy")
            }
            command.label = "Hierarchy phase \(action), pass \(iteration), rank \(rank)"
            encoder.setComputePipelineState(computePipeline)
            for (i, resource) in resources.enumerated() { encoder.setBuffer(resource, offset: 0, index: i) }
            if placement { encoder.setBuffer(mergeCounts, offset: 0, index: 11) }
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: parameterIndex)
            encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            encoder.endEncoding()
            seconds += try await submit(command)
        }
        let changed = orderScratch.contents().bindMemory(to: UInt32.self, capacity: 3 * n + temporarySize + 3).advanced(by: 3 * n + temporarySize + 2)
        try await run(action: 0)
        for sweep in 0..<(directed ? 12 : 4) {
            var anyChanged = false
            for rank in (sweep % 2 == 0 ? Array(plan.layers.indices) : Array(plan.layers.indices.reversed())) {
                try await run(action: 1, iteration: sweep, rank: rank)
                anyChanged = anyChanged || changed.pointee != 0
            }
            if directed { try await run(action: 2) }
            if !anyChanged && sweep > 0 { break }
        }
        if directed {
            if retainBest { try await run(action: 3) }
            for pass in 0..<4 {
                var anyChanged = false
                for rank in plan.layers.indices where plan.layers[rank].count > 1 {
                    try await run(action: 4, iteration: pass, rank: rank)
                    anyChanged = anyChanged || changed.pointee != 0
                }
                if !anyChanged { break }
            }
        }
        try await run(action: 5)
        for pass in 0..<3 {
            for rank in (pass % 2 == 0 ? Array(plan.layers.indices) : Array(plan.layers.indices.reversed())) {
                try await run(action: 6, iteration: pass, rank: rank)
            }
        }
        func read(_ value: any MTLBuffer, count: Int) -> [UInt32] {
            Array(UnsafeBufferPointer(start: value.contents().bindMemory(to: UInt32.self, capacity: count), count: count))
        }
        return HierarchyPlacementOutput(layers: read(layers, count: n), blockEnds: read(ends, count: 3 * n), mergeCounts: read(mergeCounts, count: 3 * n), gpuSeconds: seconds)
    }
}
#else
extension MetalForceSolver {
    func directedGeometryAsync(nodes: [LayoutNode], edges: [LayoutEdge], tolerance: Double,
                              isolation: isolated (any Actor)? = #isolation) async throws -> (score: DirectedGeometry.Score, gpuSeconds: Double) {
        throw OrganicLayoutError.metalUnavailable
    }
    func hierarchyAsync(_ plan: HierarchyPlacementPlan, directed: Bool, retainBest: Bool,
                        isolation: isolated (any Actor)? = #isolation) async throws -> HierarchyPlacementOutput {
        throw OrganicLayoutError.metalUnavailable
    }
}
#endif
