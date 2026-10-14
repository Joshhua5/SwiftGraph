import Foundation
#if canImport(Metal)
import Metal
#endif

/// A value-only program. CPU constructs order/topology; kernels evaluate geometry.
struct MetalPlacementState: Sendable {
    var bounds: [Rect]
    var flags: [UInt32]
    var records: [SIMD4<Int32>]
    var order: [UInt32]
    var childOffsets: [UInt32] = []
    var children: [UInt32] = []
    var scalars: [Double]
    var mode: UInt32
    var resource: String
    var conservativeMagnitude: Double
    var serial: Bool = false
    var nodeCount: Int? = nil
    var discreteGeometrySafe = true
    var hasWork: Bool { !order.isEmpty }
    func validatePrecision(_ tolerance: Double) throws {
        let values = bounds.flatMap { [$0.x, $0.y, $0.width, $0.height] } + scalars
        guard values.allSatisfy({ $0.isFinite && Float($0).isFinite }),
              discreteGeometrySafe, conservativeMagnitude.isFinite,
              conservativeMagnitude * 2e-7 <= tolerance else { throw LayoutExecutionError.precisionLimit }
    }
}
struct PlacementExecutionResult: Sendable {
    var bounds: [Rect]?
    var metrics: LayoutExecutionMetrics
}
extension LayoutExecutor {
    func placement(_ state: MetalPlacementState, backend: LayoutBackend) async throws -> PlacementExecutionResult {
        let start = ContinuousClock.now
        try Task.checkCancellation(); try options.validate()
        var chosen = backend, reason: LayoutFallbackReason?, output: [Rect]?, gpu: Double?, device: String?
        if !state.hasWork { chosen = .cpu; reason = .noWork }
        else if backend == .automatic {
            if (state.nodeCount ?? state.order.count) < options.minimumNodeCount { chosen = .cpu; reason = .belowThreshold }
            else if !metalEnabled || !Self.isMetalAvailable { chosen = .cpu; reason = .metalUnavailable }
            else { chosen = .metal }
        }
        if chosen == .metal {
            do {
                try state.validatePrecision(options.maximumCoordinateError)
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                if metal == nil { metal = try MetalForceSolver() }
                let result = try await metal!.placementAsync(state)
                output = result.bounds; gpu = result.gpuSeconds; device = metal!.deviceName
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu; reason = .precisionLimit
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu; reason = .metalUnavailable
            }
        }
        try Task.checkCancellation()
        let seconds = start.duration(to: .now).seconds
        return PlacementExecutionResult(bounds: output, metrics: LayoutExecutionMetrics(requestedBackend: backend,
            backend: chosen, fallbackReason: reason, nodeCount: state.nodeCount ?? state.bounds.count, iterations: state.hasWork ? 1 : 0,
            computeSeconds: seconds, totalSeconds: seconds, gpuSeconds: gpu, deviceName: device))
    }
}

#if canImport(Metal)
extension MetalForceSolver {
    func placementAsync(_ state: MetalPlacementState,
                        isolation: isolated (any Actor)? = #isolation) async throws -> (bounds: [Rect], gpuSeconds: Double) {
        let pipeline = try pipeline(resource: state.resource, function: state.serial ? "orderedPlacement" : "basicPlacement")
        let values = state.bounds.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.width), Float($0.height)) }
        let input = try buffer(values), output = try buffer(values), flags = try buffer(state.flags)
        let records = try buffer(state.records), order = try buffer(state.order)
        let offsets = try buffer(state.childOffsets), children = try buffer(state.children)
        let scalars = try buffer(state.scalars.map(Float.init))
        // Scratch accommodates stable sorting, pass-start overlap windows and tree state.
        let scratch = try buffer(Array(repeating: SIMD4<Float>.zero, count: max(1, state.bounds.count * 4 + 4)))
        defer { recycle([input, output, flags, records, order, offsets, children, scalars, scratch]) }
        struct Parameters {
            var count: UInt32; var orderCount: UInt32; var mode: UInt32; var stage: UInt32
            var start: UInt32; var end: UInt32; var padding0: UInt32 = 0; var padding1: UInt32 = 0
        }
        func encodeSteps(_ steps: [(stage: UInt32, start: Int, end: Int)]) throws -> any MTLCommandBuffer {
            guard let command = queue.makeCommandBuffer() else {
                throw OrganicLayoutError.metalFailure("Could not encode placement")
            }
            command.label = "\(state.resource) placement batch (\(steps.count) steps)"
            for step in steps {
                guard let encoder = command.makeComputeCommandEncoder() else {
                    throw OrganicLayoutError.metalFailure("Could not encode placement")
                }
                encoder.setComputePipelineState(pipeline)
                for (i, resource) in [input, output, flags, records, order, offsets, children, scalars, scratch].enumerated() {
                    encoder.setBuffer(resource, offset: 0, index: i)
                }
                var p = Parameters(count: UInt32(values.count), orderCount: UInt32(state.order.count), mode: state.mode,
                                   stage: step.stage, start: UInt32(step.start), end: UInt32(step.end))
                encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 9)
                let width = state.serial ? 1 : min(128, pipeline.maxTotalThreadsPerThreadgroup)
                let count = state.serial ? 1 : state.order.count
                encoder.dispatchThreadgroups(MTLSize(width: (count + width - 1) / width, height: 1, depth: 1),
                                             threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
                encoder.endEncoding()
            }
            return command
        }
        var gpuSeconds = 0.0, usesOverlapSweep = false
        let batch = max(1, min(64, 1_048_576 / max(1, state.bounds.count)))
        if state.resource == "BasicLayouts" && state.mode == 9 {
            var initialSteps: [(stage: UInt32, start: Int, end: Int)] = []
            for axis in 0..<2 {
                initialSteps.append((UInt32(axis * 2), 0, 0))
                for start in stride(from: 0, to: state.order.count, by: batch) {
                    initialSteps.append((UInt32(axis * 2 + 1), start, min(state.order.count, start + batch)))
                }
            }
            gpuSeconds += try await submit(encodeSteps(initialSteps))
            var separated = false
            let passesPerCommand = 4
            for _ in stride(from: 0, to: 200, by: passesPerCommand) {
                var passSteps: [(stage: UInt32, start: Int, end: Int)] = []
                for _ in 0..<passesPerCommand {
                    passSteps.append((4, 0, 0))
                    for start in stride(from: 0, to: state.order.count, by: batch) {
                        passSteps.append((5, start, min(state.order.count, start + batch)))
                    }
                }
                gpuSeconds += try await submit(encodeSteps(passSteps))
                let status = scratch.contents().bindMemory(to: SIMD4<Float>.self, capacity: state.bounds.count * 4 + 4)
                if status[state.bounds.count].x == 0 { separated = true; break }
            }
            if !separated {
                usesOverlapSweep = true
                var sweepSteps: [(stage: UInt32, start: Int, end: Int)] = [(6, 0, 0)]
                for start in stride(from: 0, to: state.bounds.count, by: batch) {
                    sweepSteps.append((7, start, min(state.bounds.count, start + batch)))
                }
                gpuSeconds += try await submit(encodeSteps(sweepSteps))
            }
        } else if state.serial {
            var serialSteps: [(stage: UInt32, start: Int, end: Int)] = []
            if (state.resource == "TreeLayouts" && (state.mode == 1 || state.mode == 3)) || (state.resource == "BasicLayouts" && (state.mode == 10 || state.mode == 11)) {
                serialSteps.append((0, 0, 0))
            }
            let workBatch = state.resource == "BasicLayouts" ? max(1, min(batch, 262_144 / max(1, state.bounds.count * state.bounds.count))) : batch
            for start in stride(from: 0, to: state.order.count, by: workBatch) {
                let firstStage: UInt32 = state.resource == "TreeLayouts" && (state.mode == 0 || state.mode == 2) && start == 0 ? 0 : 1
                serialSteps.append((firstStage, start, min(state.order.count, start + workBatch)))
            }
            gpuSeconds += try await submit(encodeSteps(serialSteps))
        } else {
            gpuSeconds += try await submit(encodeSteps([(0, 0, state.order.count)]))
        }
        try Task.checkCancellation()
        let pointer = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: values.count)
        let result = Array(UnsafeBufferPointer(start: pointer, count: values.count))
        guard result.enumerated().allSatisfy({ i, v in
            // Lane records are annotations, not graph rectangles; the CPU API
            // permits finite negative effective lane widths with negative padding.
            let helper = state.flags[i] & 16 != 0
            return v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w.isFinite && (helper || (v.z >= 0 && v.w >= 0))
        }) else {
            throw OrganicLayoutError.metalFailure("Placement produced invalid geometry")
        }
        // Formats that only translate must retain exact caller dimensions.
        let stackWidth = state.bounds.map(\.width).max() ?? 0
        return (result.enumerated().map { i, v in
            let resizes = (state.resource == "TreeLayouts" && state.mode == 3) || (state.resource == "BasicLayouts" && state.mode == 6) || (state.flags[i] & 16 != 0)
            if state.flags[i] & 8 == 0 && !(usesOverlapSweep && state.resource == "BasicLayouts" && state.mode == 9) { return state.bounds[i] }
            let aligns = state.resource == "BasicLayouts" && state.mode == 7
            let horizontal = state.records[i].x, vertical = state.records[i].y
            let movesX = !aligns || (horizontal >= 1 && horizontal <= 3) || (horizontal == 7 && state.scalars[0] > 0)
            let movesY = !aligns || (vertical >= 4 && vertical <= 6) || (vertical == 7 && state.scalars[0] > 0)
            let width = state.resource == "BasicLayouts" && state.mode == 6 ? stackWidth : (resizes ? Double(v.z) : state.bounds[i].width)
            return Rect(x: movesX ? Double(v.x) : state.bounds[i].x, y: movesY ? Double(v.y) : state.bounds[i].y,
                        width: width, height: state.resource == "BasicLayouts" && state.mode == 6 ? state.bounds[i].height : (resizes ? Double(v.w) : state.bounds[i].height))
        }, gpuSeconds)
    }
}
#else
extension MetalForceSolver {
    func placementAsync(_ state: MetalPlacementState,
                        isolation: isolated (any Actor)? = #isolation) async throws -> (bounds: [Rect], gpuSeconds: Double) {
        throw OrganicLayoutError.metalUnavailable
    }
}
#endif
