import Foundation
#if canImport(Metal)
import Metal

final class MetalForceSolver {
    static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipeline: any MTLComputePipelineState
    var deviceName: String { device.name }
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
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: options)
        guard let function = library.makeFunction(name: "organicStep") else {
            throw OrganicLayoutError.metalFailure("Missing organicStep kernel")
        }
        pipeline = try device.makeComputePipelineState(function: function)
        guard pipeline.maxTotalThreadsPerThreadgroup >= 128 else {
            throw OrganicLayoutError.metalFailure("Kernel requires 128 threads per threadgroup")
        }
    }
    private func buffer<T>(_ values: [T]) throws -> any MTLBuffer {
        let length = max(1, values.count * MemoryLayout<T>.stride)
        guard let result = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw OrganicLayoutError.metalFailure("Could not allocate \(length) bytes")
        }
        if !values.isEmpty {
            values.withUnsafeBytes { bytes in result.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
        }
        return result
    }
    struct Parameters {
        var count: UInt32
        var temperature: Float
        var repulsionSquared: Float
        var attraction: Float
    }
    func solve(_ state: ForceState, iterations: Int, temperature: Float, parameters: ForceParameters, batchSize: Int) throws -> (positions: [SIMD2<Float>], gpuSeconds: Double) {
        var input = try buffer(state.positions), output = try buffer(state.positions)
        let fixed = try buffer(state.fixed), offsets = try buffer(state.offsets), neighbors = try buffer(state.neighbors)
        var gpuSeconds = 0.0
        let batch = min(batchSize, 64) // Bound both cancellation latency and command-buffer size.
        for start in stride(from: 0, to: iterations, by: batch) {
            try Task.checkCancellation()
            guard let command = queue.makeCommandBuffer() else { throw OrganicLayoutError.metalFailure("Could not create command buffer") }
            command.label = "Organic layout iterations \(start)..<\(min(iterations, start + batch))"
            for step in start..<min(iterations, start + batch) {
                guard let encoder = command.makeComputeCommandEncoder() else { throw OrganicLayoutError.metalFailure("Could not create compute encoder") }
                encoder.setComputePipelineState(pipeline)
                for (i, resource) in [input, output, fixed, offsets, neighbors].enumerated() {
                    encoder.setBuffer(resource, offset: 0, index: i)
                }
                var p = Parameters(count: UInt32(state.positions.count), temperature: temperature * (1 - Float(step) / Float(iterations)),
                                   repulsionSquared: parameters.repulsionSquared, attraction: parameters.attraction)
                encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 5)
                encoder.dispatchThreadgroups(MTLSize(width: (state.positions.count + 127) / 128, height: 1, depth: 1),
                                             threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
                // Separate serial passes + tracked buffers establish the dependency between iterations.
                encoder.endEncoding()
                swap(&input, &output)
            }
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else {
                throw OrganicLayoutError.metalFailure(command.error?.localizedDescription ?? "Command buffer did not complete")
            }
            gpuSeconds += max(0, command.gpuEndTime - command.gpuStartTime)
        }
        try Task.checkCancellation()
        let pointer = input.contents().bindMemory(to: SIMD2<Float>.self, capacity: state.positions.count)
        return (Array(UnsafeBufferPointer(start: pointer, count: state.positions.count)), gpuSeconds)
    }
}
#else
final class MetalForceSolver {
    static var isAvailable: Bool { false }
    var deviceName: String { "Unavailable" }
    init() throws { throw OrganicLayoutError.metalUnavailable }
    func solve(_ state: ForceState, iterations: Int, temperature: Float, parameters: ForceParameters, batchSize: Int) throws -> (positions: [SIMD2<Float>], gpuSeconds: Double) {
        throw OrganicLayoutError.metalUnavailable
    }
}
#endif
