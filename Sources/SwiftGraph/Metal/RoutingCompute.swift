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

    static func checkCancellation() throws {
        try Task.checkCancellation()
        try cancellation?.check()
    }

    let solver: MetalForceSolver
    let tolerance: Float
    var failure: (any Error)?
    var gpuSeconds = 0.0
    var stages: [String] = []

    /// Calls that exceeded a Metal limit and took the CPU path instead; reported with the CPU stages.
    private(set) var fallbacks: [String] = []

    /// Largest matrix or grid one dispatch may allocate (64 MiB of UInt32 flags).
    static let maximumElements = 16_777_216

    /// Below these sizes the exact CPU predicates finish sooner than a blocking GPU round trip, whichever backend was
    /// requested.
    static let roundTripPairs = 65_536
    static let roundTripElements = 8_192
    var minimumPairs = 0
    var minimumElements = 0

    /// Explicit `.metal` still sends its first call to the GPU so the transaction exercises Metal (stages, precision
    /// limits, cancellation); later calls below the round-trip threshold take the exact CPU path.
    var dispatchesFirstCall = false

    /// `stages` gains an entry on the first dispatch, so an empty list means nothing has reached the GPU yet.
    private func admits(_ work: Int, minimum: Int) -> Bool {
        work >= minimum || (dispatchesFirstCall && stages.isEmpty)
    }

    let statisticsChanged: () -> Void

    init(solver: MetalForceSolver, tolerance: Float, statisticsChanged: @escaping () -> Void) {
        self.tolerance = tolerance
        self.solver = solver
        self.statisticsChanged = statisticsChanged
    }

    /// Scans a slice `[start..<end]` of a `UInt32` flag buffer (where each element is `0` or `1`)
    /// using Darwin's NEON-vectorized `memchr` so zero spans are skipped at hardware speed.
    private static func scanFlagIndices(
        _ flags: UnsafeBufferPointer<UInt32>,
        from start: Int,
        to end: Int,
        _ body: (Int) -> Void
    ) {
        guard start < end, let base = flags.baseAddress else { return }
        let rawBase = UnsafeRawPointer(base)
        let endByte = end * 4
        var nextIndex = start
        while nextIndex < end {
            let startByte = nextIndex * 4
            guard let found = memchr(rawBase + startByte, 1, endByte - startByte) else { break }
            let index = rawBase.distance(to: UnsafeRawPointer(found)) >> 2
            body(index)
            nextIndex = index + 1
        }
    }

    // Outward rounding makes rejection safe even at huge absolute coordinates. Accepted candidates
    // receive the original predicate, preserving boundary and ordered-search decisions exactly.
    private func box(_ r: Rect) throws -> SIMD4<Float> {
        let values = [
            min(r.left, r.right).nextDown, min(r.top, r.bottom).nextDown, max(r.left, r.right).nextUp,
            max(r.top, r.bottom).nextUp,
        ]
        guard values.allSatisfy(\.isFinite) else { throw LayoutExecutionError.precisionLimit }
        return SIMD4(values[0], values[1], values[2], values[3])
    }

    private func fallback(_ note: String) { if !fallbacks.contains(note) { fallbacks.append(note) } }

    /// Nil sends the caller to its exact CPU path: below the work threshold, or beyond the matrix limit.
    func candidates(_ left: [Rect], _ right: [Rect]) -> [UInt32]? {
        guard !left.isEmpty, !right.isEmpty else { return [] }
        let pairs = left.count * right.count
        guard admits(pairs, minimum: minimumPairs) else { return nil }
        guard left.count <= Self.maximumElements / right.count else {
            fallback("CPU fallback: geometry matrix exceeds the Metal 64 MiB limit")
            return nil
        }
        do {
            try Self.checkCancellation()
            return try dispatchBoxes(left.map(box), right.map(box))
        } catch {
            if failure == nil { failure = error }
            return nil
        }
    }

    private func withCandidateBuffer<R>(
        _ left: [Rect],
        _ right: [Rect],
        _ body: (UnsafeBufferPointer<UInt32>) -> R
    ) -> R? {
        guard !left.isEmpty, !right.isEmpty else {
            return body(UnsafeBufferPointer(start: nil, count: 0))
        }
        let pairs = left.count * right.count
        guard admits(pairs, minimum: minimumPairs) else { return nil }
        guard left.count <= Self.maximumElements / right.count else {
            fallback("CPU fallback: geometry matrix exceeds the Metal 64 MiB limit")
            return nil
        }
        do {
            try Self.checkCancellation()
            return try withDispatchedBoxBuffer(left.map(box), right.map(box), body)
        } catch {
            if failure == nil { failure = error }
            return nil
        }
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
            let handled = withCandidateBuffer(part.map { Self.bounds($0.0, $0.1) }, obstacles) { flags in
                let obsCount = obstacles.count
                for (s, segment) in part.enumerated() {
                    let rowBase = s * obsCount
                    Self.scanFlagIndices(flags, from: rowBase, to: rowBase + obsCount) { idx in
                        let r = idx - rowBase
                        if !result.contains(r) && obstacles[r].intersectsLine(segment.0, segment.1) {
                            result.insert(r)
                        }
                    }
                }
            }
            if handled == nil {
                for r in obstacles.indices
                where !result.contains(r) && part.contains(where: { obstacles[r].intersectsLine($0.0, $0.1) }) {
                    result.insert(r)
                }
            }
        }
        return result
    }

    func intersections(_ rect: Rect, _ obstacles: [Rect]) -> [Int] {
        if let res = withCandidateBuffer(
            [rect],
            obstacles,
            { flags -> [Int] in
                var filtered: [Int] = []
                Self.scanFlagIndices(flags, from: 0, to: obstacles.count) { i in
                    if rect.intersects(obstacles[i]) { filtered.append(i) }
                }
                return filtered
            }
        ) {
            return res
        }
        return obstacles.indices.filter { rect.intersects(obstacles[$0]) }
    }

    /// Visibility stays on the CPU lazy search. A V²×N candidate matrix with a synchronous wait per
    /// batch computes every pair, where the quadtree-pruned search only asks about the few it visits.
    func visibility(_ points: [Point], _ obstacles: [Rect]) -> [Bool]? { nil }

    func overlapMatrix(_ segments: [(start: Point, end: Point)], padding: Float = 0) -> [UInt32]? {
        let boxes = segments.map { Self.bounds($0.start, $0.end).inflated(by: padding) }
        return candidates(boxes, boxes)
    }

    /// Dispatches conservative bounding-box rejection on Metal when within the 64 MiB matrix limit,
    /// then scans the GPU flag buffer directly via vectorized `memchr` to yield upper-triangular
    /// candidate pairs `j > i` without allocating a copy or iterating over zero cells in Swift.
    func overlapPairs(_ segments: [(start: Point, end: Point)], padding: Float = 0) -> [[Int]]? {
        guard segments.count > 1 else { return Array(repeating: [], count: segments.count) }
        let boxes = segments.map { Self.bounds($0.start, $0.end).inflated(by: padding) }
        return withCandidateBuffer(boxes, boxes) { flags in
            let count = boxes.count
            var pairs = Array(repeating: [Int](), count: count)
            for i in 0..<(count - 1) {
                let rowBase = i * count
                var list: [Int] = []
                Self.scanFlagIndices(flags, from: rowBase + i + 1, to: rowBase + count) { idx in
                    list.append(idx - rowBase)
                }
                pairs[i] = list
            }
            return pairs
        }
    }

    func contains(_ points: [Point], _ rect: Rect) -> [Bool] {
        let boxes = points.map { Rect(x: $0.x, y: $0.y) }
        if let res = withCandidateBuffer(
            boxes,
            [rect],
            { flags -> [Bool] in
                points.indices.map { flags[$0] != 0 && rect.contains(points[$0]) }
            }
        ) {
            return res
        }
        return points.map(rect.contains)
    }

    /// Rectangles whose open span (closed with `closed`) contains each value; the CPU filter in
    /// `OrthogonalGroupedEdgeRouter` must agree.
    func axisBlockers(_ values: [Float], rectangles: [Rect], vertical: Bool, closed: Bool = false) -> [[Int]]? {
        guard
            let low = rectangles.map({ vertical ? $0.top : $0.left }).min(),
            let high = rectangles.map({ vertical ? $0.bottom : $0.right }).max()
        else {
            return Array(repeating: [], count: values.count)
        }
        let lines = values.map {
            vertical ? Rect(x: $0, y: low, height: high - low) : Rect(x: low, y: $0, width: high - low)
        }
        return withCandidateBuffer(lines, rectangles) { flags in
            let rectCount = rectangles.count
            return values.enumerated()
                .map { i, value -> [Int] in
                    let rowBase = i * rectCount
                    var list: [Int] = []
                    Self.scanFlagIndices(flags, from: rowBase, to: rowBase + rectCount) { idx in
                        let j = idx - rowBase
                        let r = rectangles[j]
                        let (lo, hi) = vertical ? (r.left, r.right) : (r.top, r.bottom)
                        if closed ? (lo <= value && value <= hi) : (lo < value && value < hi) {
                            list.append(j)
                        }
                    }
                    return list
                }
        }
    }

    func occupiedCells(_ rectangles: [SIMD4<Int32>]) -> [SIMD2<Int32>]? {
        guard
            let minX = rectangles.map(\.x).min(),
            let minY = rectangles.map(\.y).min(),
            let maxX = rectangles.map(\.z).max(),
            let maxY = rectangles.map(\.w).max()
        else {
            return []
        }
        do {
            try Self.checkCancellation()
            let width = Int(maxX) - Int(minX) + 1
            let height = Int(maxY) - Int(minY) + 1
            guard width > 0, height > 0 else { return nil }
            guard width <= Self.maximumElements / height else {
                fallback("CPU fallback: channel occupancy grid exceeds the Metal 64 MiB limit")
                return nil
            }
            guard admits(width * height * rectangles.count, minimum: minimumPairs) else { return nil }
            return try withDispatchedOccupancyBuffer(
                rectangles,
                origin: SIMD2(minX, minY),
                width: width,
                count: width * height
            ) { flags in
                var res: [SIMD2<Int32>] = []
                Self.scanFlagIndices(flags, from: 0, to: flags.count) { i in
                    res.append(SIMD2(minX + Int32(i % width), minY + Int32(i / width)))
                }
                return res
            }
        } catch {
            if failure == nil { failure = error }
            return nil
        }
    }

    func octilinear(_ starts: [Point], _ ends: [Point]) -> [Point]? {
        geometry("routingOctilinear", starts, ends, offsets: Array(repeating: 0, count: starts.count))
    }

    func parallel(_ starts: [Point], _ ends: [Point], offsets: [Float]) -> [Point]? {
        geometry("routingParallel", starts, ends, offsets: offsets)
    }

    func bus(_ hub: Point, others: [Point], coordinate: Float, horizontal: Bool) -> [Point]? {
        let starts = Array(repeating: hub, count: others.count * 2)
        let ends = others.flatMap { [$0, $0] }
        let offset = coordinate - (horizontal ? hub.y : hub.x)
        return geometry(
            horizontal ? "routingBusHorizontal" : "routingBusVertical",
            starts,
            ends,
            offsets: Array(repeating: offset, count: starts.count)
        )
    }

    private func geometry(_ function: String, _ a: [Point], _ b: [Point], offsets: [Float]) -> [Point]? {
        guard !a.isEmpty else { return [] }
        guard admits(a.count, minimum: minimumElements) else { return nil }
        do {
            try Self.checkCancellation()
            let origin = a[0]
            let extent = (a + b)
                .reduce(offsets.map(abs).max() ?? 0) { max($0, max(abs($1.x - origin.x), abs($1.y - origin.y))) }
            guard extent.isFinite, extent.ulp * 32 <= tolerance else { throw LayoutExecutionError.precisionLimit }
            let aa = a.map { SIMD2($0.x - origin.x, $0.y - origin.y) }
            let bb = b.map { SIMD2($0.x - origin.x, $0.y - origin.y) }
            return try dispatchBlend(aa, bb, offsets, function: function)
                .map { Point(x: origin.x + $0.x, y: origin.y + $0.y) }
        } catch {
            if failure == nil { failure = error }
            return nil
        }
    }

    /// Weighted-point geometry is computed on Metal. The caller retains original endpoints.
    func blend(_ a: [Point], _ b: [Point], weights: [Float]) -> [Point]? {
        guard !a.isEmpty else { return [] }
        guard admits(a.count, minimum: minimumElements) else { return nil }
        do {
            try Self.checkCancellation()
            let origin = a[0]
            let extent = (a + b).reduce(Float(0)) { max($0, max(abs($1.x - origin.x), abs($1.y - origin.y))) }
            guard extent.isFinite, extent.ulp * 16 <= tolerance else { throw LayoutExecutionError.precisionLimit }
            let aa = a.map { SIMD2($0.x - origin.x, $0.y - origin.y) }
            let bb = b.map { SIMD2($0.x - origin.x, $0.y - origin.y) }
            let values = try dispatchBlend(aa, bb, weights)
            return values.map { Point(x: origin.x + $0.x, y: origin.y + $0.y) }
        } catch {
            if failure == nil { failure = error }
            return nil
        }
    }
    #if canImport(Metal)

    private struct OccupancyGridUniforms {
        var origin: SIMD2<Int32>
        var width: UInt32
        var rectangles: UInt32
    }

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
        struct Parameters {
            var start: UInt32
            var count: UInt32
            var rightCount: UInt32
            var padding: UInt32 = 0
        }
        for start in stride(from: 0, to: count, by: batch) {
            try Self.checkCancellation()
            guard let command = solver.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
            else {
                throw OrganicLayoutError.metalFailure("Could not encode routing geometry")
            }
            command.label = "Routing \(function)"
            encoder.setComputePipelineState(pipeline)
            for (i, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: i) }
            let n = min(batch, count - start)
            var parameters = Parameters(start: UInt32(start), count: UInt32(n), rightCount: UInt32(rightCount))
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: buffers.count)
            let width = min(128, pipeline.maxTotalThreadsPerThreadgroup)
            encoder.dispatchThreadgroups(
                MTLSize(width: (n + width - 1) / width, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
            )
            encoder.endEncoding()
            solver.submittedBatches += 1
            statisticsChanged()
            command.commit()
            // This worker is detached from the caller's actor. Cancellation must drain the command
            // before its leased buffers are recycled or the transaction reports cancellation.
            command.waitUntilCompleted()
            gpuSeconds += try solver.check(command)
            statisticsChanged()
        }
        try Self.checkCancellation()
    }

    private func withDispatchedBoxBuffer<R>(
        _ left: [SIMD4<Float>],
        _ right: [SIMD4<Float>],
        _ body: (UnsafeBufferPointer<UInt32>) -> R
    ) throws -> R {
        var buffers: [any MTLBuffer] = []
        defer {
            solver.recycle(buffers)
            statisticsChanged()
        }
        let n = left.count * right.count
        buffers.append(try solver.buffer(left))
        buffers.append(try solver.buffer(right))
        buffers.append(try solver.buffer(byteCount: n * MemoryLayout<UInt32>.stride))
        try execute("routingBoxCandidates", buffers: buffers, count: n, rightCount: right.count)
        let pointer = buffers[2].contents().bindMemory(to: UInt32.self, capacity: n)
        return body(UnsafeBufferPointer(start: pointer, count: n))
    }

    private func dispatchBoxes(_ left: [SIMD4<Float>], _ right: [SIMD4<Float>]) throws -> [UInt32] {
        try withDispatchedBoxBuffer(left, right) { Array($0) }
    }

    private func withDispatchedOccupancyBuffer<R>(
        _ rectangles: [SIMD4<Int32>],
        origin: SIMD2<Int32>,
        width: Int,
        count: Int,
        _ body: (UnsafeBufferPointer<UInt32>) -> R
    ) throws -> R {
        var buffers: [any MTLBuffer] = []
        defer {
            solver.recycle(buffers)
            statisticsChanged()
        }
        buffers.append(try solver.buffer(rectangles))
        buffers.append(
            try solver.buffer([
                OccupancyGridUniforms(origin: origin, width: UInt32(width), rectangles: UInt32(rectangles.count))
            ])
        )
        buffers.append(try solver.buffer(byteCount: count * MemoryLayout<UInt32>.stride))
        try execute("routingOccupancy", buffers: buffers, count: count)
        let pointer = buffers[2].contents().bindMemory(to: UInt32.self, capacity: count)
        return body(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func dispatchBlend(
        _ a: [SIMD2<Float>],
        _ b: [SIMD2<Float>],
        _ weights: [Float],
        function: String = "routingBlend"
    ) throws -> [SIMD2<Float>] {
        var buffers: [any MTLBuffer] = []
        defer {
            solver.recycle(buffers)
            statisticsChanged()
        }
        buffers.append(try solver.buffer(a))
        buffers.append(try solver.buffer(b))
        buffers.append(try solver.buffer(weights))
        buffers.append(try solver.buffer(byteCount: a.count * MemoryLayout<SIMD2<Float>>.stride))
        try execute(function, buffers: buffers, count: a.count)
        return solver.result(buffers[3], count: a.count)
    }
    #else

    private func withDispatchedOccupancyBuffer<R>(
        _ rectangles: [SIMD4<Int32>],
        origin: SIMD2<Int32>,
        width: Int,
        count: Int,
        _ body: (UnsafeBufferPointer<UInt32>) -> R
    ) throws -> R { throw OrganicLayoutError.metalUnavailable }

    private func withDispatchedBoxBuffer<R>(
        _ left: [SIMD4<Float>],
        _ right: [SIMD4<Float>],
        _ body: (UnsafeBufferPointer<UInt32>) -> R
    ) throws -> R { throw OrganicLayoutError.metalUnavailable }

    private func dispatchBoxes(_ left: [SIMD4<Float>], _ right: [SIMD4<Float>]) throws -> [UInt32] {
        throw OrganicLayoutError.metalUnavailable
    }

    private func dispatchBlend(
        _ a: [SIMD2<Float>],
        _ b: [SIMD2<Float>],
        _ weights: [Float],
        function: String = "routingBlend"
    ) throws -> [SIMD2<Float>] { throw OrganicLayoutError.metalUnavailable }
    #endif
}
