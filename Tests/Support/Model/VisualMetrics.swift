import Foundation
import SwiftGraph

struct VisualMetrics: Codable, Equatable, Sendable {
    var values: [String: Double]
    var findings: [VisualFinding]
    var failures: [VisualFinding]
}
