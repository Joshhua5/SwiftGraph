import Foundation

extension OrganicLayoutOperation: LayoutExecutionReporting {
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
}

extension EdgeBundlingOperation: LayoutExecutionReporting {
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
}

extension BarycenterLayoutOperation: LayoutExecutionReporting {
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
}
