import Foundation
import SwiftGraph

public struct BackendComparativeReport: Codable, Sendable {
    public var version: Int = 1
    public var generatedAt: String
    public var deviceName: String
    public var environment: [String: String]
    public var totalCases: Int
    public var trialsPerCase: Int
    public var families: [FamilyAggregateSummary]
    public var bottleneckCounts: [String: Int]
    public var cases: [ComparativeCaseResult]
}
