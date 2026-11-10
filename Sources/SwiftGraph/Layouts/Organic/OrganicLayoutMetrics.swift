import Foundation

public struct OrganicLayoutMetrics: Sendable {
    public let backend: OrganicBackend
    public let nodeCount: Int
    public let iterations: Int

    /// Includes preparation, buffer allocation, submission, waiting and graph write-back; excludes solver
    /// initialization.
    public let wallTimeSeconds: Double

    /// Command-buffer GPU time only. Nil on CPU backends.
    public let gpuTimeSeconds: Double?
}
