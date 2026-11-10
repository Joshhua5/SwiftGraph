import Foundation

func compositionCPURecord(
    _ requested: LayoutBackend,
    count: Int,
    start: ContinuousClock.Instant,
    stages: [String]
) -> LayoutExecutionMetrics {
    let seconds = start.duration(to: .now).seconds
    var metrics = LayoutExecutionMetrics(
        requestedBackend: requested,
        backend: .cpu,
        fallbackReason: nil,
        nodeCount: count,
        iterations: 1,
        computeSeconds: seconds,
        totalSeconds: seconds,
        gpuSeconds: nil,
        deviceName: nil
    )
    metrics.cpuStages = stages
    return metrics
}

/// Synchronous CPU adapters cannot report their own metrics. Preserve their work
/// in the composite record; arbitrary async cores should conform to reporting.
func compositionCoreRecords(
    _ core: any AsyncLayoutAlgorithm,
    requested: LayoutBackend,
    graph: LayoutGraph,
    start: ContinuousClock.Instant
) -> [LayoutExecutionMetrics] {
    if let reporting = core as? any LayoutExecutionReporting { return reporting.lastExecutionMetrics }
    guard core is any LayoutAlgorithm else { return [] }
    return [
        compositionCPURecord(
            requested,
            count: graph.nodes.count,
            start: start,
            stages: ["caller-supplied CPU core layout"]
        )
    ]
}
