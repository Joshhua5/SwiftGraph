import Foundation

/// Thread-safe profiler that captures hierarchical stage timings alongside `LayoutStageScope`.
public final class LayoutStageProfiler: @unchecked Sendable {
    @TaskLocal public static var current: LayoutStageProfiler?
    private let lock = NSLock()
    private var entries: [String: LayoutStageTiming] = [:]
    private var order: [String] = []

    public init() {}

    func record(path: [String], seconds: Double, metalDispatches: Int = 0, metalGpuSeconds: Double = 0) {
        guard !path.isEmpty else { return }
        let key = path.joined(separator: " › ")
        lock.lock()
        defer { lock.unlock() }
        if var existing = entries[key] {
            existing.callCount += 1
            existing.totalSeconds += seconds
            existing.maxSingleSeconds = max(existing.maxSingleSeconds, seconds)
            existing.metalDispatches += metalDispatches
            existing.metalGpuSeconds += metalGpuSeconds
            entries[key] = existing
        } else {
            order.append(key)
            entries[key] = LayoutStageTiming(
                path: path,
                callCount: 1,
                totalSeconds: seconds,
                maxSingleSeconds: seconds,
                metalDispatches: metalDispatches,
                metalGpuSeconds: metalGpuSeconds
            )
        }
    }

    public func timings() -> [LayoutStageTiming] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { entries[$0] }
    }
}

/// Runs `operation` while collecting exact per-stage wall-clock and Metal dispatch timings across all nested stages.
public func withLayoutStageProfiling<T>(
    _ operation: () async throws -> T
) async rethrows -> (value: T, stages: [LayoutStageTiming]) {
    let profiler = LayoutStageProfiler()
    let sink = LayoutProgressSink(handler: { _ in }, minimumInterval: .seconds(3600))
    let value = try await LayoutStageProfiler.$current.withValue(profiler) {
        try await withLayoutProgress(sink, operation: operation)
    }
    return (value, profiler.timings())
}
