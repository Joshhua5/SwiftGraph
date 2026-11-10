import Foundation

struct RoutingResult: Sendable {
    var bounds: [Rect]
    var rootBounds: Rect
    var paths: [[Point]]
    var labels: [Rect]
    var unroutable: [Int]
    var metrics: LayoutExecutionMetrics
}
