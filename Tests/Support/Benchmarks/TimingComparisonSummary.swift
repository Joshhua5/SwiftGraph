import Foundation
import SwiftGraph

public struct TimingComparisonSummary: Codable, Sendable {
    public var trials: Int
    public var cpuColdMs: Double
    public var cpuWarmMedianMs: Double
    public var cpuWarmMinMs: Double
    public var cpuWarmMaxMs: Double
    public var metalColdMs: Double
    public var metalWarmMedianMs: Double
    public var metalWarmMinMs: Double
    public var metalWarmMaxMs: Double
    public var metalComputeMedianMs: Double
    public var metalGpuKernelMedianMs: Double?
    public var metalCpuPrepMedianMs: Double
    public var metalOverheadMedianMs: Double
    public var gpuUtilizationFraction: Double
    public var speedupVsCPU: Double
    public var kernelSpeedupVsCPU: Double?
    public var submittedBatches: Int
    public var completedBatches: Int
    public var pipelineBuilds: Int
    public var bufferAllocations: Int
    public var bufferReuses: Int
    public var automaticChoseBackend: String
    public var automaticFallbackReason: String?
    public var precisionLimitExceededDefault: Bool
    public var metalStages: [String]
    public var cpuStagesInMetalMode: [String]
}
