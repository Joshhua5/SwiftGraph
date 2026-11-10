import Foundation
import SwiftGraph

public struct OutputComparisonSummary: Codable, Sendable {
    public var nodeCount: Int
    public var edgeCount: Int
    public var groupCount: Int
    public var changedNodeCount: Int
    public var changedEdgeCount: Int
    public var edgePointCountMismatches: Int
    public var rawNodeCenterRMS: Double
    public var rawNodeCenterMax: Double
    public var maxNodeBoundsDelta: Double
    public var centroidAlignedNodeRMS: Double
    public var centroidAlignedNodeMax: Double
    public var maxEdgePointDeviation: Double
    public var meanEdgePointDeviation: Double
    public var cpuContractFailures: [String]
    public var metalContractFailures: [String]
    public var cpuMetrics: [String: Double]
    public var metalMetrics: [String: Double]
    public var metricDeltas: [String: Double]
    public var qualityFlags: [String]
    public var parityClassification: ParityClassification
}
