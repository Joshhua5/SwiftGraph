import Foundation
import SwiftGraph

public struct ComparativeCaseResult: Codable, Sendable {
    public var id: String
    public var family: String
    public var title: String
    public var configuration: [String: String]
    public var output: OutputComparisonSummary
    public var timing: TimingComparisonSummary
    public var bottlenecks: [BottleneckFinding]
    public var notes: [String]
}
