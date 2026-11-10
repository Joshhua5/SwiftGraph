import Foundation

/// A serial queue owns all routing compute resources. Awaiting callers transfer only values;
/// synchronous command draining happens on this dedicated queue, never a cooperative executor.
final class RoutingComputeWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SwiftGraph.routing.compute")
    private var solver: MetalForceSolver?
    private let lock = NSLock()
    private var statistics = LayoutExecutorStatistics(
        pipelineBuilds: 0,
        bufferAllocations: 0,
        bufferReuses: 0,
        submittedBatches: 0,
        completedBatches: 0,
        cachedBufferBytes: 0
    )

    func statisticsSnapshot() -> LayoutExecutorStatistics {
        lock.lock()
        defer { lock.unlock() }
        return statistics
    }

    private func updateStatistics() {
        guard let solver else { return }
        let value = LayoutExecutorStatistics(
            pipelineBuilds: solver.pipelineBuilds,
            bufferAllocations: solver.bufferAllocations,
            bufferReuses: solver.bufferReuses,
            submittedBatches: solver.submittedBatches,
            completedBatches: solver.completedBatches,
            cachedBufferBytes: solver.cachedBufferBytes
        )
        lock.lock()
        statistics = value
        lock.unlock()
    }

    func releaseCachedBuffers() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.solver?.releaseCachedBuffers()
                self.updateStatistics()
                continuation.resume()
            }
        }
    }

    func run(
        _ snapshot: RoutingSnapshot,
        configuration: RoutingConfiguration,
        backend: LayoutBackend,
        enabled: Bool,
        tolerance: Float
    ) async throws -> RoutingResult {
        let cancellation = RoutingCancellation()
        // Task-locals do not cross the queue hop; progress is re-bound beside the cancellation flag.
        let progress = LayoutStageScope.capture()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        let result = try progress.bind {
                            try RoutingCompute.$cancellation.withValue(cancellation) {
                                try routingTransaction(
                                    snapshot,
                                    configuration: configuration,
                                    backend: backend,
                                    enabled: enabled,
                                    tolerance: tolerance
                                ) {
                                    if self.solver == nil { self.solver = try MetalForceSolver() }
                                    self.updateStatistics()
                                    // `solver` was assigned above if it was still nil.
                                    return RoutingCompute(
                                        solver: self.solver!,
                                        tolerance: tolerance,
                                        statisticsChanged: self.updateStatistics
                                    )
                                }
                            }
                        }
                        self.updateStatistics()
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch {
                        self.updateStatistics()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
