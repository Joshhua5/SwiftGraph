import Foundation

/// Execution records for successfully completed backend-aware operations.
/// Composite operations report each child separately, in execution order.
public protocol LayoutExecutionReporting: AsyncLayoutAlgorithm {
    var lastExecutionMetrics: [LayoutExecutionMetrics] { get }
}
