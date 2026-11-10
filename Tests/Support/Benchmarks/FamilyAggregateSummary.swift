import Foundation
import SwiftGraph

public struct FamilyAggregateSummary: Codable, Sendable {
    public var family: String
    public var caseCount: Int
    public var exactParityCount: Int
    public var floatEquivalentCount: Int
    public var heuristicDivergentCount: Int
    public var qualityRegressionCount: Int
    public var cpuTotalWarmMs: Double
    public var metalTotalWarmMs: Double
    public var gpuKernelTotalMs: Double
    public var medianSpeedup: Double
    public var meanGpuUtilization: Double
    public var fasterOnMetalCount: Int
    public var slowerOnMetalCount: Int
}
