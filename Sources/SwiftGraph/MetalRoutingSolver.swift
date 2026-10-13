import Foundation
#if canImport(Metal)
import Metal
#endif

/// A transaction-local compute owner. It is created, used and destroyed on one detached worker;
/// TaskLocal supplies it to synchronous CPU orchestration without sharing it between requests.
final class RoutingCompute: @unchecked Sendable {
    @TaskLocal static var current: RoutingCompute?
    @TaskLocal static var cancellation: RoutingCancellation?
    static var isCancelled: Bool { Task.isCancelled || cancellation?.isCancelled == true }
    static func checkCancellation() throws { try Task.checkCancellation(); try cancellation?.check() }
    let solver: MetalForceSolver
    let tolerance: Double
    var failure: (any Error)?
    var gpuSeconds = 0.0
    var stages: [String] = []
    /// Calls that exceeded a Metal limit and took the CPU path instead; reported with the CPU stages.
    private(set) var fallbacks: [String] = []
    /// Largest matrix or grid one dispatch may allocate (64 MiB of UInt32 flags).
    static let maximumElements = 16_777_216
    /// Automatic runs skip the blocking GPU round trip for calls the CPU predicates finish sooner.
    static let automaticPairs = 65_536, automaticElements = 8_192
    var minimumPairs = 0, minimumElements = 0
    let statisticsChanged: () -> Void
    init(solver: MetalForceSolver, tolerance: Double, statisticsChanged: @escaping () -> Void) {
        self.tolerance = tolerance; self.solver = solver; self.statisticsChanged = statisticsChanged
    }

    // Outward rounding makes rejection safe even at huge absolute coordinates. Accepted candidates
    // receive the original Double predicate, preserving boundary and ordered-search decisions exactly.
    private func box(_ r: Rect) throws -> SIMD4<Float> {
        let values = [Float(min(r.left, r.right)).nextDown, Float(min(r.top, r.bottom)).nextDown, Float(max(r.left, r.right)).nextUp, Float(max(r.top, r.bottom)).nextUp]
        guard values.allSatisfy(\.isFinite) else { throw LayoutExecutionError.precisionLimit }
        return SIMD4(values[0], values[1], values[2], values[3])
    }
    private func fallback(_ note: String) { if !fallbacks.contains(note) { fallbacks.append(note) } }
    /// Nil sends the caller to its exact CPU path: below the work threshold, or beyond the matrix limit.
    func candidates(_ left: [Rect], _ right: [Rect]) -> [UInt32]? {
        guard !left.isEmpty, !right.isEmpty else { return [] }
        guard left.count * right.count >= minimumPairs else { return nil }
        guard left.count <= Self.maximumElements / right.count else {
            fallback("CPU fallback: geometry matrix exceeds the Metal 64 MiB limit"); return nil
        }
        do {
            try Self.checkCancellation()
            return try dispatchBoxes(left.map(box), right.map(box))
        } catch { if failure == nil { failure = error }; return nil }
    }
    static func bounds(_ a: Point, _ b: Point) -> Rect {
        Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    /// Segments are chunked so the flag matrix stays within the dispatch limit however long the path is.
    func hits(_ path: [Point], _ obstacles: [Rect]) -> Set<Int> {
        let segments = Array(zip(path, path.dropFirst()))
        var result = Set<Int>()
        let step = max(1, Self.maximumElements / max(1, obstacles.count))
        for start in stride(from: 0, to: segments.count, by: step) {
            let part = segments[start..<min(segments.count, start + step)]
            if let flags = candidates(part.map { Self.bounds($0.0, $0.1) }, obstacles) {
                for (s, segment) in part.enumerated() {
                    for r in obstacles.indices where flags[s * obstacles.count + r] != 0 && !result.contains(r) {
                        if obstacles[r].intersectsLine(segment.0, segment.1) { result.insert(r) }
                    }
                }
            } else {
                for r in obstacles.indices where !result.contains(r) && part.contains(where: { obstacles[r].intersectsLine($0.0, $0.1) }) { result.insert(r) }
            }
        }
        return result
    }
    func intersections(_ rect: Rect, _ obstacles: [Rect]) -> [Int] {
        guard let flags = candidates([rect], obstacles) else { return obstacles.indices.filter { rect.intersects(obstacles[$0]) } }
        return obstacles.indices.filter { flags[$0] != 0 && rect.intersects(obstacles[$0]) }
    }
    /// Visibility stays on the CPU lazy search. A V²×N candidate matrix with a synchronous wait per
    /// batch computes every pair, where the quadtree-pruned search only asks about the few it visits.
    func visibility(_ points: [Point], _ obstacles: [Rect]) -> [Bool]? { nil }
    func overlapMatrix(_ segments: [(start: Point, end: Point)], padding: Double = 0) -> [UInt32]? {
        let boxes = segments.map { Self.bounds($0.start, $0.end).inflated(by: padding) }
        return candidates(boxes, boxes)
    }
    func contains(_ points: [Point], _ rect: Rect) -> [Bool] {
        let boxes = points.map { Rect(x: $0.x, y: $0.y) }
        guard let flags = candidates(boxes, [rect]) else { return points.map(rect.contains) }
        return points.indices.map { flags[$0] != 0 && rect.contains(points[$0]) }
    }
    /// Rectangles whose open span (closed with `closed`) contains each value; the CPU filter in `OrthogonalGroupedEdgeRouter` must agree.
    func axisBlockers(_ values: [Double], rectangles: [Rect], vertical: Bool, closed: Bool = false) -> [[Int]]? {
        guard !rectangles.isEmpty else { return Array(repeating: [], count: values.count) }
        let low = rectangles.map { vertical ? $0.top : $0.left }.min()!
        let high = rectangles.map { vertical ? $0.bottom : $0.right }.max()!
        let lines = values.map { vertical ? Rect(x: $0, y: low, height: high - low) : Rect(x: low, y: $0, width: high - low) }
        guard let flags = candidates(lines, rectangles) else { return nil }
        return values.enumerated().map { i, value in rectangles.indices.filter { j in
            flags[i * rectangles.count + j] != 0 && {
                let (low, high) = vertical ? (rectangles[j].left, rectangles[j].right) : (rectangles[j].top, rectangles[j].bottom)
                return closed ? low <= value && value <= high : low < value && value < high
            }()
        } }
    }
    func occupiedCells(_ rectangles: [SIMD4<Int32>]) -> [SIMD2<Int32>]? {
        guard !rectangles.isEmpty else { return [] }
        do {
            try Self.checkCancellation()
            let minX = rectangles.map(\.x).min()!, minY = rectangles.map(\.y).min()!
            let maxX = rectangles.map(\.z).max()!, maxY = rectangles.map(\.w).max()!
            let width = Int(maxX) - Int(minX) + 1, height = Int(maxY) - Int(minY) + 1
            guard width > 0, height > 0 else { return nil }
            guard width <= Self.maximumElements / height else { fallback("CPU fallback: channel occupancy grid exceeds the Metal 64 MiB limit"); return nil }
            guard width * height * rectangles.count >= minimumPairs else { return nil }
            let flags = try dispatchOccupancy(rectangles, origin: SIMD2(minX, minY), width: width, count: width * height)
            return flags.indices.compactMap { flags[$0] == 0 ? nil : SIMD2(minX + Int32($0 % width), minY + Int32($0 / width)) }
        } catch { if failure == nil { failure = error }; return nil }
    }
    func octilinear(_ starts: [Point], _ ends: [Point]) -> [Point]? {
        geometry("routingOctilinear", starts, ends, offsets: Array(repeating: 0, count: starts.count))
    }
    func parallel(_ starts: [Point], _ ends: [Point], offsets: [Double]) -> [Point]? {
        geometry("routingParallel", starts, ends, offsets: offsets)
    }
    func bus(_ hub: Point, others: [Point], coordinate: Double, horizontal: Bool) -> [Point]? {
        let starts = Array(repeating: hub, count: others.count * 2)
        let ends = others.flatMap { [$0, $0] }
        let offset = coordinate - (horizontal ? hub.y : hub.x)
        return geometry(horizontal ? "routingBusHorizontal" : "routingBusVertical", starts, ends, offsets: Array(repeating: offset, count: starts.count))
    }
    private func geometry(_ function: String, _ a: [Point], _ b: [Point], offsets: [Double]) -> [Point]? {
        guard !a.isEmpty else { return [] }
        guard a.count >= minimumElements else { return nil }
        do {
            try Self.checkCancellation()
            let origin = a[0]
            let extent = (a + b).reduce(offsets.map(abs).max() ?? 0) { max($0, max(abs($1.x - origin.x), abs($1.y - origin.y))) }
            guard Float(extent).isFinite, Double(Float(extent).ulp) * 32 <= tolerance else { throw LayoutExecutionError.precisionLimit }
            let aa = a.map { SIMD2(Float($0.x - origin.x), Float($0.y - origin.y)) }, bb = b.map { SIMD2(Float($0.x - origin.x), Float($0.y - origin.y)) }
            return try dispatchBlend(aa, bb, offsets.map(Float.init), function: function).map { Point(x: origin.x + Double($0.x), y: origin.y + Double($0.y)) }
        } catch { if failure == nil { failure = error }; return nil }
    }
    /// Weighted-point geometry is computed on Metal. The caller retains original Double endpoints.
    func blend(_ a: [Point], _ b: [Point], weights: [Double]) -> [Point]? {
        guard !a.isEmpty else { return [] }
        guard a.count >= minimumElements else { return nil }
        do {
            try Self.checkCancellation()
            let origin = a[0]
            let extent = (a + b).reduce(0.0) { max($0, max(abs($1.x - origin.x), abs($1.y - origin.y))) }
            guard Float(extent).isFinite, Double(Float(extent).ulp) * 16 <= tolerance else { throw LayoutExecutionError.precisionLimit }
            let aa = a.map { SIMD2(Float($0.x - origin.x), Float($0.y - origin.y)) }
            let bb = b.map { SIMD2(Float($0.x - origin.x), Float($0.y - origin.y)) }
            let values = try dispatchBlend(aa, bb, weights.map(Float.init))
            return values.map { Point(x: origin.x + Double($0.x), y: origin.y + Double($0.y)) }
        } catch { if failure == nil { failure = error }; return nil }
    }
#if canImport(Metal)
    private func execute(_ function: String, buffers: [any MTLBuffer], count: Int, rightCount: Int = 0) throws {
        let pipeline = try solver.pipeline(resource: "Routing", function: function)
        let stage: String
        switch function {
        case "routingBoxCandidates": stage = "conservative collision and visibility candidate rejection"
        case "routingOccupancy": stage = "integer channel-grid occupancy rasterization"
        case "routingOctilinear": stage = "octilinear bend geometry"
        case "routingParallel": stage = "parallel-edge midpoint and normal offsets"
        case "routingBusHorizontal", "routingBusVertical": stage = "bus joint geometry"
        default: stage = "curve subdivision geometry"
        }
        if !stages.contains(stage) { stages.append(stage) }
        // Bound dispatched pair work per command to permit cancellation between drained batches.
        let batch = 262_144
        struct Parameters { var start: UInt32; var count: UInt32; var rightCount: UInt32; var padding: UInt32 = 0 }
        for start in stride(from: 0, to: count, by: batch) {
            try Self.checkCancellation()
            guard let command = solver.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw OrganicLayoutError.metalFailure("Could not encode routing geometry")
            }
            command.label = "Routing \(function)"
            encoder.setComputePipelineState(pipeline)
            for (i, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: i) }
            let n = min(batch, count - start)
            var parameters = Parameters(start: UInt32(start), count: UInt32(n), rightCount: UInt32(rightCount))
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: buffers.count)
            let width = min(128, pipeline.maxTotalThreadsPerThreadgroup)
            encoder.dispatchThreadgroups(MTLSize(width: (n + width - 1) / width, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            encoder.endEncoding(); solver.submittedBatches += 1; statisticsChanged(); command.commit()
            // This worker is detached from the caller's actor. Cancellation must drain the command
            // before its leased buffers are recycled or the transaction reports cancellation.
            command.waitUntilCompleted(); gpuSeconds += try solver.check(command); statisticsChanged()
        }
        try Self.checkCancellation()
    }
    private func dispatchBoxes(_ left: [SIMD4<Float>], _ right: [SIMD4<Float>]) throws -> [UInt32] {
        var buffers: [any MTLBuffer] = []
        defer { solver.recycle(buffers); statisticsChanged() }
        buffers.append(try solver.buffer(left)); buffers.append(try solver.buffer(right))
        let n = left.count * right.count
        buffers.append(try solver.buffer(Array(repeating: UInt32(0), count: n)))
        try execute("routingBoxCandidates", buffers: buffers, count: n, rightCount: right.count)
        let pointer = buffers[2].contents().bindMemory(to: UInt32.self, capacity: n)
        return Array(UnsafeBufferPointer(start: pointer, count: n))
    }
    private func dispatchOccupancy(_ rectangles: [SIMD4<Int32>], origin: SIMD2<Int32>, width: Int, count: Int) throws -> [UInt32] {
        struct Grid { var origin: SIMD2<Int32>; var width: UInt32; var rectangles: UInt32 }
        var buffers: [any MTLBuffer] = []
        defer { solver.recycle(buffers); statisticsChanged() }
        buffers.append(try solver.buffer(rectangles)); buffers.append(try solver.buffer([Grid(origin: origin, width: UInt32(width), rectangles: UInt32(rectangles.count))])); buffers.append(try solver.buffer(Array(repeating: UInt32(0), count: count)))
        try execute("routingOccupancy", buffers: buffers, count: count)
        let pointer = buffers[2].contents().bindMemory(to: UInt32.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
    private func dispatchBlend(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>], _ weights: [Float], function: String = "routingBlend") throws -> [SIMD2<Float>] {
        var buffers: [any MTLBuffer] = []
        defer { solver.recycle(buffers); statisticsChanged() }
        buffers.append(try solver.buffer(a)); buffers.append(try solver.buffer(b)); buffers.append(try solver.buffer(weights)); buffers.append(try solver.buffer(a))
        try execute(function, buffers: buffers, count: a.count)
        return solver.result(buffers[3], count: a.count)
    }
#else
    private func dispatchOccupancy(_ rectangles: [SIMD4<Int32>], origin: SIMD2<Int32>, width: Int, count: Int) throws -> [UInt32] { throw OrganicLayoutError.metalUnavailable }
    private func dispatchBoxes(_ left: [SIMD4<Float>], _ right: [SIMD4<Float>]) throws -> [UInt32] { throw OrganicLayoutError.metalUnavailable }
    private func dispatchBlend(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>], _ weights: [Float], function: String = "routingBlend") throws -> [SIMD2<Float>] { throw OrganicLayoutError.metalUnavailable }
#endif
}
