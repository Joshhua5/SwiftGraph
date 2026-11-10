import Foundation
import SwiftGraph

struct VisualDrawing {
    var graph: LayoutGraph
    var previousBounds: [String: Rect] = [:]
    var fixedCenters: [String: Point] = [:]
    var fallbackEdges: [Int] = []
    var edgeWidths: [Float] = []
    var reportedMetrics: [String: Double] = [:]
    var notes: [String] = []
    var additionalFailures: [VisualFinding] = []
    var bidirectionalEdges: Set<Int> = []
}
