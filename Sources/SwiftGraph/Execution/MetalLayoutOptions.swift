import Foundation

/// Conservative, configurable heuristics; automatic selection is opt-in, not a universal crossover.
public struct MetalLayoutOptions: Sendable {
    public var minimumNodeCount = 1_024
    public var minimumIterations = 10
    public var minimumBundlingEdgeCount = 256

    /// Radial layouts are selected by within-ring pair count, independent of iteration thresholds.
    public var minimumRadialPairCount = 131_072
    public var iterationsPerBatch = 8

    /// Float precision allowance: coordinate ULP for forces/averaging, and pair-ranking error for radial clearance.
    public var maximumCoordinateError: Float = 0.01

    public init() {}

    func validate() throws {
        guard minimumNodeCount >= 0, minimumIterations >= 0, minimumBundlingEdgeCount >= 0, minimumRadialPairCount >= 0,
            iterationsPerBatch > 0,
            maximumCoordinateError.isFinite, maximumCoordinateError > 0
        else {
            throw LayoutExecutionError.invalidInput("Invalid Metal selection, batch or precision options.")
        }
    }
}
