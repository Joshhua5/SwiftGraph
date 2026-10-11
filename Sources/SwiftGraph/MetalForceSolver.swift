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
    var pipelineBuilds: Int { bundlingPipeline == nil ? 1 : 2 }
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
    }
    private func encode(_ state: ForceState, iterations: Int, temperature: Float, parameters: ForceParameters,
                        steps: Range<Int>, input: inout any MTLBuffer, output: inout any MTLBuffer,
                        fixed: any MTLBuffer, offsets: any MTLBuffer, neighbors: any MTLBuffer) throws -> any MTLCommandBuffer {
        guard let command = queue.makeCommandBuffer() else { throw OrganicLayoutError.metalFailure("Could not create command buffer") }
        command.label = "Organic layout iterations \(steps)"
        for step in steps {
            guard let encoder = command.makeComputeCommandEncoder() else { throw OrganicLayoutError.metalFailure("Could not create compute encoder") }
            encoder.setComputePipelineState(pipeline)
            for (i, resource) in [input, output, fixed, offsets, neighbors].enumerated() { encoder.setBuffer(resource, offset: 0, index: i) }
            var p = Parameters(count: UInt32(state.positions.count), temperature: temperature * (1 - Float(step) / Float(iterations)),
                               repulsionSquared: parameters.repulsionSquared, attraction: parameters.attraction)
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
                    isolation: isolated (any Actor)? = #isolation) async throws -> (positions: [SIMD2<Float>], gpuSeconds: Double) {
        var input = try buffer(state.positions), output = try buffer(state.positions)
        let fixed = try buffer(state.fixed), offsets = try buffer(state.offsets), neighbors = try buffer(state.neighbors)
        defer { recycle([input, output, fixed, offsets, neighbors]) }
        var gpuSeconds = 0.0
        let batch = min(max(1, batchSize), 64)
        for start in stride(from: 0, to: iterations, by: batch) {
            try Task.checkCancellation()
            let command = try encode(state, iterations: iterations, temperature: temperature, parameters: parameters,
                steps: start..<min(iterations, start + batch), input: &input, output: &output, fixed: fixed, offsets: offsets, neighbors: neighbors)
            submittedBatches += 1
            // Cancellation never resumes early: shared buffers must remain leased until the GPU is done.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in continuation.resume() }
                command.commit()
            }
            gpuSeconds += try check(command)
        }
        try Task.checkCancellation()
        return (result(input, count: state.positions.count), gpuSeconds)
    }
    private func getBundlingPipeline() throws -> any MTLComputePipelineState {
        if bundlingPipeline == nil {
            guard let function = library.makeFunction(name: "bundlingStep") else { throw OrganicLayoutError.metalFailure("Missing bundlingStep kernel") }
            bundlingPipeline = try device.makeComputePipelineState(function: function)
        }
        return bundlingPipeline!
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
    init() throws { throw OrganicLayoutError.metalUnavailable }
    func solve(_ state: ForceState, iterations: Int, temperature: Float, parameters: ForceParameters, batchSize: Int) throws -> (positions: [SIMD2<Float>], gpuSeconds: Double) {
        throw OrganicLayoutError.metalUnavailable
    }
    func solveAsync(_ state: ForceState, iterations: Int, temperature: Float, parameters: ForceParameters, batchSize: Int,
                    isolation: isolated (any Actor)? = #isolation) async throws -> (positions: [SIMD2<Float>], gpuSeconds: Double) {
        throw OrganicLayoutError.metalUnavailable
    }
    func bundleAsync(_ state: BundlingState, iterations: Int, batchSize: Int,
                     isolation: isolated (any Actor)? = #isolation) async throws -> (positions: [SIMD2<Float>], gpuSeconds: Double) {
        throw OrganicLayoutError.metalUnavailable
    }
}
#endif
