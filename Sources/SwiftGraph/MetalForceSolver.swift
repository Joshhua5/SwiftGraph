import Foundation
#if canImport(Metal)
import Metal

/// Confined to its executor (or to the synchronous spike's caller). Checked-out buffers are never pooled
/// until the command buffer completes, including when the awaiting task has been cancelled.
final class MetalForceSolver {
    static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let library: any MTLLibrary
    let pipeline: any MTLComputePipelineState
    var bundlingPipeline: (any MTLComputePipelineState)?
    var barycenterPipeline: (any MTLComputePipelineState)?
    var radialPipeline: (any MTLComputePipelineState)?
    private var additionalLibraries: [String: any MTLLibrary] = [:]
    private var additionalPipelines: [String: any MTLComputePipelineState] = [:]
    var pipelineBuilds: Int { 1 + (bundlingPipeline == nil ? 0 : 1) + (barycenterPipeline == nil ? 0 : 1) + (radialPipeline == nil ? 0 : 1) + additionalPipelines.count }
    var deviceName: String { device.name }
    private var pool: [any MTLBuffer] = []
    private(set) var bufferAllocations = 0
    private(set) var bufferReuses = 0
    var submittedBatches = 0
    var completedBatches = 0
    private(set) var cachedBufferBytes = 0
    private let maximumCachedBytes = 64 * 1_024 * 1_024
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw OrganicLayoutError.metalUnavailable
        }
        self.device = device; self.queue = queue
        guard let url = Bundle.module.url(forResource: "OrganicForces", withExtension: "metal", subdirectory: "Shaders") else {
            throw OrganicLayoutError.metalFailure("Missing packaged OrganicForces.metal resource")
        }
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: options)
        guard let function = library.makeFunction(name: "organicStep") else {
            throw OrganicLayoutError.metalFailure("Missing organicStep kernel")
        }
        pipeline = try device.makeComputePipelineState(function: function)
        guard pipeline.maxTotalThreadsPerThreadgroup >= 128 else {
            throw OrganicLayoutError.metalFailure("Kernel requires 128 threads per threadgroup")
        }
    }
    func releaseCachedBuffers() { pool.removeAll(); cachedBufferBytes = 0 }
    /// Loads independent kernel families without making each backend extension
    /// mutate the shared shader or maintain a separate device/resource pool.
    func pipeline(resource: String, function: String) throws -> any MTLComputePipelineState {
        let key = resource + ":" + function
        if let cached = additionalPipelines[key] { return cached }
        let compiled: any MTLLibrary
        if let cached = additionalLibraries[resource] { compiled = cached }
        else {
            guard let url = Bundle.module.url(forResource: resource, withExtension: "metal", subdirectory: "Shaders") else {
                throw OrganicLayoutError.metalFailure("Missing packaged \(resource).metal resource")
            }
            let options = MTLCompileOptions(); options.fastMathEnabled = false
            compiled = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: options)
            additionalLibraries[resource] = compiled
        }
        guard let kernel = compiled.makeFunction(name: function) else {
            throw OrganicLayoutError.metalFailure("Missing \(function) kernel in \(resource).metal")
        }
        let result = try device.makeComputePipelineState(function: kernel)
        additionalPipelines[key] = result
        return result
    }
    /// Buffers remain leased through completion even when cancellation arrives.
    func submit(_ command: any MTLCommandBuffer,
                isolation: isolated (any Actor)? = #isolation) async throws -> Double {
        try Task.checkCancellation()
        submittedBatches += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        let seconds = try check(command)
        try Task.checkCancellation()
        return seconds
    }
    func buffer<T>(_ values: [T]) throws -> any MTLBuffer {
        let length = max(1, values.count * MemoryLayout<T>.stride)
        let result: any MTLBuffer
        if let index = pool.indices.filter({ pool[$0].length >= length }).min(by: { pool[$0].length < pool[$1].length }) {
            result = pool.remove(at: index); cachedBufferBytes -= result.length; bufferReuses += 1
        } else {
            var capacity = 256
            while capacity < length && capacity <= device.maxBufferLength / 2 { capacity *= 2 }
            capacity = max(capacity, length)
            guard capacity <= device.maxBufferLength, let allocation = device.makeBuffer(length: capacity, options: .storageModeShared) else {
                throw OrganicLayoutError.metalFailure("Could not allocate \(capacity) bytes")
            }
            result = allocation; bufferAllocations += 1
        }
        if !values.isEmpty {
            values.withUnsafeBytes { bytes in result.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
        }
        return result
    }
    func recycle(_ buffers: [any MTLBuffer]) {
        for buffer in buffers where cachedBufferBytes + buffer.length <= maximumCachedBytes {
            pool.append(buffer); cachedBufferBytes += buffer.length
        }
    }
    struct Parameters {
        var count: UInt32
        var temperature: Float
        var repulsionSquared: Float
        var attraction: Float
        var treeCount: UInt32 = 0
    }
    private func encode(_ state: ForceState, iterations: Int, temperature: Float, parameters: ForceParameters,
                        steps: Range<Int>, input: inout any MTLBuffer, output: inout any MTLBuffer,
                        fixed: any MTLBuffer, offsets: any MTLBuffer, neighbors: any MTLBuffer,
                        computePipeline: (any MTLComputePipelineState)? = nil,
                        coolingIterationBudget: Double? = nil,
                        treeBuffers: [any MTLBuffer]? = nil, treeCount: Int = 0) throws -> any MTLCommandBuffer {
        guard let command = queue.makeCommandBuffer() else { throw OrganicLayoutError.metalFailure("Could not create command buffer") }
        command.label = "Organic layout iterations \(steps)"
        for step in steps {
            guard let encoder = command.makeComputeCommandEncoder() else { throw OrganicLayoutError.metalFailure("Could not create compute encoder") }
            encoder.setComputePipelineState(computePipeline ?? pipeline)
            for (i, resource) in [input, output, fixed, offsets, neighbors].enumerated() { encoder.setBuffer(resource, offset: 0, index: i) }
            // Exact-force and barycenter dispatches bind unused slots too, so
            // argument validation remains complete when the tree branch is disabled.
            for (i, resource) in (treeBuffers ?? Array(repeating: fixed, count: 6)).enumerated() {
                encoder.setBuffer(resource, offset: 0, index: i + 6)
            }
            let cooled: Float
            if let budget = coolingIterationBudget {
                cooled = Float(max(0, Double(temperature) * (1 - Double(step) / budget)))
            } else { cooled = temperature * (1 - Float(step) / Float(iterations)) }
            var p = Parameters(count: UInt32(state.positions.count), temperature: cooled,
                               repulsionSquared: parameters.repulsionSquared, attraction: parameters.attraction, treeCount: UInt32(treeCount))
            encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 5)
            encoder.dispatchThreadgroups(MTLSize(width: (state.positions.count + 127) / 128, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            encoder.endEncoding()
            swap(&input, &output)
        }
        return command
    }
    func result(_ buffer: any MTLBuffer, count: Int) -> [SIMD2<Float>] {
        let pointer = buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
    func check(_ command: any MTLCommandBuffer) throws -> Double {
        completedBatches += 1
        guard command.status == .completed else {
            throw OrganicLayoutError.metalFailure(command.error?.localizedDescription ?? "Command buffer did not complete")
        }
        return max(0, command.gpuEndTime - command.gpuStartTime)
    }
    // Explicitly blocking compatibility entry point for the original spike.
    func solve(_ state: ForceState, iterations: Int, temperature: Float, parameters: ForceParameters, batchSize: Int) throws -> (positions: [SIMD2<Float>], gpuSeconds: Double) {
        var input = try buffer(state.positions), output = try buffer(state.positions)
        let fixed = try buffer(state.fixed), offsets = try buffer(state.offsets), neighbors = try buffer(state.neighbors)
        defer { recycle([input, output, fixed, offsets, neighbors]) }
        var gpuSeconds = 0.0
        for start in stride(from: 0, to: iterations, by: min(max(1, batchSize), 64)) {
            try Task.checkCancellation()
            let command = try encode(state, iterations: iterations, temperature: temperature, parameters: parameters,
                steps: start..<min(iterations, start + min(max(1, batchSize), 64)), input: &input, output: &output, fixed: fixed, offsets: offsets, neighbors: neighbors)
            submittedBatches += 1; command.commit(); command.waitUntilCompleted()
            gpuSeconds += try check(command)
        }
        try Task.checkCancellation()
        return (result(input, count: state.positions.count), gpuSeconds)
    }
    func solveAsync(_ state: ForceState, iterations: Int, temperature: Float, parameters: ForceParameters, batchSize: Int,
                    barycenter: Bool = false, coolingIterationBudget: Double? = nil,
                    isolation: isolated (any Actor)? = #isolation) async throws -> (positions: [SIMD2<Float>], gpuSeconds: Double, cpuPreparationSeconds: Double) {
        let computePipeline = barycenter ? try getBarycenterPipeline() : pipeline
        var input = try buffer(state.positions), output = try buffer(state.positions)
        let fixed = try buffer(state.fixed), offsets = try buffer(state.offsets), neighbors = try buffer(state.neighbors)
        defer { recycle([input, output, fixed, offsets, neighbors]) }
        var gpuSeconds = 0.0
        var cpuPreparationSeconds = 0.0
        let batch = max(1, batchSize)
        if !barycenter && state.positions.count >= 64 {
            // ForceQuadTree is rebuilt after every CPU iteration. A drained command
            // gives topology preparation the same preceding-iteration positions.
            let perturbations = try buffer(state.positions.indices.map { i -> SIMD2<Float> in
                let angle = Double(i) * 2.399963229728653
                return SIMD2(Float(cos(angle) * 0.1), Float(sin(angle) * 0.1))
            })
            defer { recycle([perturbations]) }
            let treeStride = (coolingIterationBudget != nil && iterations >= 60) ? max(1, min(batch, 15)) : 1
            for iteration in stride(from: 0, to: iterations, by: treeStride) {
                try Task.checkCancellation()
                let preparationStart = ContinuousClock.now
                let tree = try OrganicForceTree(result(input, count: state.positions.count))
                guard tree.cells.count < Int(UInt32.max) else { throw LayoutExecutionError.invalidInput("Organic tree exceeds Metal index capacity") }
                let leaves = tree.gpuLeaves
                var leased: [any MTLBuffer] = []
                defer { recycle(leased) }
                func lease<T>(_ values: [T]) throws -> any MTLBuffer { let allocation = try buffer(values); leased.append(allocation); return allocation }
                let resources = [try lease(tree.gpuBounds), try lease(tree.gpuCenters), try lease(tree.gpuChildren),
                    try lease(leaves.ranges), try lease(leaves.bodies), perturbations]
                cpuPreparationSeconds += preparationStart.duration(to: .now).seconds
                let command = try encode(state, iterations: iterations, temperature: temperature, parameters: parameters,
                    steps: iteration..<min(iterations, iteration + treeStride), input: &input, output: &output, fixed: fixed, offsets: offsets, neighbors: neighbors,
                    coolingIterationBudget: coolingIterationBudget,
                    treeBuffers: resources, treeCount: tree.cells.count)
                gpuSeconds += try await submit(command)
            }
            try Task.checkCancellation()
            return (result(input, count: state.positions.count), gpuSeconds, cpuPreparationSeconds)
        }
        for start in stride(from: 0, to: iterations, by: batch) {
            try Task.checkCancellation()
            let command = try encode(state, iterations: iterations, temperature: temperature, parameters: parameters,
                steps: start..<min(iterations, start + batch), input: &input, output: &output, fixed: fixed, offsets: offsets, neighbors: neighbors,
                computePipeline: computePipeline, coolingIterationBudget: coolingIterationBudget)
            submittedBatches += 1
            // Cancellation never resumes early: shared buffers must remain leased until the GPU is done.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in continuation.resume() }
                command.commit()
            }
            gpuSeconds += try check(command)
        }
        try Task.checkCancellation()
        return (result(input, count: state.positions.count), gpuSeconds, cpuPreparationSeconds)
    }
    private func getBarycenterPipeline() throws -> any MTLComputePipelineState {
        if barycenterPipeline == nil {
            guard let function = library.makeFunction(name: "barycenterStep") else { throw OrganicLayoutError.metalFailure("Missing barycenterStep kernel") }
            let value = try device.makeComputePipelineState(function: function)
            guard value.maxTotalThreadsPerThreadgroup >= 128 else { throw OrganicLayoutError.metalFailure("Kernel requires 128 threads per threadgroup") }
            barycenterPipeline = value
        }
        return barycenterPipeline!
    }
    private func getBundlingPipeline() throws -> any MTLComputePipelineState {
        if bundlingPipeline == nil {
            guard let function = library.makeFunction(name: "bundlingStep") else { throw OrganicLayoutError.metalFailure("Missing bundlingStep kernel") }
            bundlingPipeline = try device.makeComputePipelineState(function: function)
        }
        return bundlingPipeline!
    }
    private func getRadialPipeline() throws -> any MTLComputePipelineState {
        if radialPipeline == nil {
            guard let function = library.makeFunction(name: "radialClearance") else { throw OrganicLayoutError.metalFailure("Missing radialClearance kernel") }
            let value = try device.makeComputePipelineState(function: function)
            guard value.maxTotalThreadsPerThreadgroup >= 128 else { throw OrganicLayoutError.metalFailure("Radial kernel requires 128 threads per threadgroup") }
            radialPipeline = value
        }
        return radialPipeline!
    }
    func radialClearanceAsync(_ state: RadialClearanceState,
                              isolation: isolated (any Actor)? = #isolation) async throws -> (partners: [UInt32], gpuSeconds: Double) {
        let pipeline = try getRadialPipeline()
        let angles = try buffer(state.angles), diameters = try buffer(state.diameters)
        let ends = try buffer(state.ends), output = try buffer(Array(repeating: UInt32(0), count: state.angles.count))
        defer { recycle([angles, diameters, ends, output]) }
        var gpuSeconds = 0.0
        // Bound pair work per command so cancellation can drain without retaining
        // a single command for the entire quadratic scan. No shared scratch state.
        let batch = max(1, 1_048_576 / max(1, state.maximumRingSize))
        struct Parameters { var start: UInt32; var count: UInt32 }
        for start in stride(from: 0, to: state.angles.count, by: batch) {
            try Task.checkCancellation()
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw OrganicLayoutError.metalFailure("Could not encode radial clearance")
            }
            command.label = "Radial ring clearance"
            encoder.setComputePipelineState(pipeline)
            for (i, resource) in [angles, diameters, ends, output].enumerated() { encoder.setBuffer(resource, offset: 0, index: i) }
            let count = min(batch, state.angles.count - start)
            var p = Parameters(start: UInt32(start), count: UInt32(count))
            encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 4)
            encoder.dispatchThreadgroups(MTLSize(width: count, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            encoder.endEncoding(); submittedBatches += 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in continuation.resume() }; command.commit()
            }
            gpuSeconds += try check(command)
        }
        try Task.checkCancellation()
        let pointer = output.contents().bindMemory(to: UInt32.self, capacity: state.angles.count)
        return (Array(UnsafeBufferPointer(start: pointer, count: state.angles.count)), gpuSeconds)
    }
    func bundleAsync(_ state: BundlingState, iterations: Int, batchSize: Int,
                     isolation: isolated (any Actor)? = #isolation) async throws -> (positions: [SIMD2<Float>], gpuSeconds: Double) {
        let pipeline = try getBundlingPipeline()
        var input = try buffer(state.positions), output = try buffer(state.positions)
        let offsets = try buffer(state.offsets), compatible = try buffer(state.compatible), springs = try buffer(state.springs)
        defer { recycle([input, output, offsets, compatible, springs]) }
        var gpuSeconds = 0.0
        let work = Double(state.compatible.count) * Double(max(1, state.segments - 1))
        let workBound = max(1, Int(min(64, 16_777_216 / max(1, work))))
        let batch = min(max(1, batchSize), workBound)
        struct Parameters { var count: UInt32; var segments: UInt32; var step: Float; var padding: UInt32 = 0 }
        for start in stride(from: 0, to: iterations, by: batch) {
            try Task.checkCancellation()
            guard let command = queue.makeCommandBuffer() else { throw OrganicLayoutError.metalFailure("Could not create command buffer") }
            command.label = "Edge bundling iterations \(start)..<\(min(iterations, start + batch))"
            for iteration in start..<min(iterations, start + batch) {
                guard let encoder = command.makeComputeCommandEncoder() else { throw OrganicLayoutError.metalFailure("Could not create compute encoder") }
                encoder.setComputePipelineState(pipeline)
                for (i, resource) in [input, output, offsets, compatible, springs].enumerated() { encoder.setBuffer(resource, offset: 0, index: i) }
                var p = Parameters(count: UInt32(state.positions.count), segments: UInt32(state.segments), step: Float(0.1 * (1 - Double(iteration) / Double(iterations))))
                encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 5)
                let width = min(128, pipeline.maxTotalThreadsPerThreadgroup)
                encoder.dispatchThreadgroups(MTLSize(width: (state.positions.count + width - 1) / width, height: 1, depth: 1),
                                             threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
                encoder.endEncoding(); swap(&input, &output)
            }
            submittedBatches += 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in continuation.resume() }
                command.commit()
            }
            gpuSeconds += try check(command)
        }
        try Task.checkCancellation()
        return (result(input, count: state.positions.count), gpuSeconds)
    }
}
#else
final class MetalForceSolver {
    static var isAvailable: Bool { false }
    var deviceName: String { "Unavailable" }
    var pipelineBuilds: Int { 0 }
    var bufferAllocations: Int { 0 }
    var bufferReuses: Int { 0 }
    var submittedBatches: Int { 0 }
    var completedBatches: Int { 0 }
    var cachedBufferBytes: Int { 0 }
    func releaseCachedBuffers() {}
    func radialClearanceAsync(_ state: RadialClearanceState,
                              isolation: isolated (any Actor)? = #isolation) async throws -> (partners: [UInt32], gpuSeconds: Double) {
        throw OrganicLayoutError.metalUnavailable
    }
    init() throws { throw OrganicLayoutError.metalUnavailable }
    func solve(_ state: ForceState, iterations: Int, temperature: Float, parameters: ForceParameters, batchSize: Int) throws -> (positions: [SIMD2<Float>], gpuSeconds: Double) {
        throw OrganicLayoutError.metalUnavailable
    }
    func solveAsync(_ state: ForceState, iterations: Int, temperature: Float, parameters: ForceParameters, batchSize: Int,
                    barycenter: Bool = false, coolingIterationBudget: Double? = nil,
                    isolation: isolated (any Actor)? = #isolation) async throws -> (positions: [SIMD2<Float>], gpuSeconds: Double, cpuPreparationSeconds: Double) {
        throw OrganicLayoutError.metalUnavailable
    }
    func bundleAsync(_ state: BundlingState, iterations: Int, batchSize: Int,
                     isolation: isolated (any Actor)? = #isolation) async throws -> (positions: [SIMD2<Float>], gpuSeconds: Double) {
        throw OrganicLayoutError.metalUnavailable
    }
}
#endif
