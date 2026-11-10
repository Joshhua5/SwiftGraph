import Foundation

public struct LayoutExecutionMetrics: Sendable {
    public let requestedBackend: LayoutBackend
    public let backend: LayoutBackend
    public let fallbackReason: LayoutFallbackReason?
    public let nodeCount: Int
    public let iterations: Int

    /// Compute-side preparation, lazy pipeline creation, submission, waiting and readback.
    public internal(set) var computeSeconds: Double

    /// Includes snapshot capture, executor queueing and graph write-back when obtained from an operation.
    public internal(set) var totalSeconds: Double
    public let gpuSeconds: Double?
    public let deviceName: String?

    /// CPU tree rebuilding and upload within organic Metal solves; included in computeSeconds.
    public internal(set) var cpuPreparationSeconds: Double = 0

    /// Stages executed on CPU, including preparation or exact reconstruction in hybrid operations.
    public internal(set) var cpuStages: [String] = []

    /// Stages that actually submitted computation to Metal; empty for CPU/no-work execution.
    public internal(set) var metalStages: [String] = []

    /// Organic quality CPU preparation, candidate solves and CPU quality cleanup/scoring.
    /// Nil for operations that do not run a candidate search. Solver time includes
    /// backend preparation, submission and readback, not just GPU execution.
    public internal(set) var qualityPhases: OrganicQualityTimings? = nil
}
