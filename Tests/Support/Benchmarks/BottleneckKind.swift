import Foundation
import SwiftGraph

public enum BottleneckKind: String, Codable, CaseIterable, Sendable {
    case noMetalStagesSubmitted
    case lowGpuUtilization
    case highMicroDispatchOverhead
    case metalSlowerThanCPU
    case unacceleratedPipelineStage
    case precisionLimitFallback
    case thresholdFallback
    case qualityRegression
}
