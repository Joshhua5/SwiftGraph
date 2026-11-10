import Foundation

public struct OrganicLayoutDiagnostics: Sendable {
    /// Includes the unchanged input candidate, at index zero.
    public var candidateCount: Int
    public var selectedCandidate: Int
    public var solverIterations: Int

    /// Stable node indices. These constraints cannot be resolved without moving a fixed node.
    public var fixedConflicts: [[Int]]
    public var initial: OrganicQualityMeasurements
    public var final: OrganicQualityMeasurements
}
