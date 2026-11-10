import Foundation

/// A named slice of the overall progress range, passed implicitly to nested work through a task-local.
/// Each stage reports either through child `run` stages or through `tick`, never both for the same work.
final class LayoutStageScope: Sendable {
    @TaskLocal static var current: LayoutStageScope?
    let sink: LayoutProgressSink
    let stages: [String]
    let lower: Double
    let upper: Double

    init(sink: LayoutProgressSink) {
        self.sink = sink
        stages = []
        lower = 0
        upper = 1
    }

    private init(parent: LayoutStageScope, name: String, from: Double, to: Double) {
        let width = parent.upper - parent.lower
        let start = min(max(from, 0), 1)
        let end = min(max(to, start), 1)
        sink = parent.sink
        stages = parent.stages + [name]
        lower = parent.lower + width * start
        upper = parent.lower + width * end
    }

    fileprivate func report(_ local: Double) {
        sink.offer(lower + (upper - lower) * min(max(local, 0), 1), scope: self)
    }

    /// Runs `body` as a child stage owning `from...to` of the current stage. On normal return the stage
    /// snaps to complete, which covers loops that exit early. With no listener this is one task-local read.
    @inline(__always)
    static func run<T>(
        _ name: @autoclosure () -> String,
        from: Double = 0,
        to: Double = 1,
        _ body: () throws -> T
    ) rethrows -> T {
        let profiler = LayoutStageProfiler.current
        guard let parent = current else {
            guard let profiler else { return try body() }
            let stageName = name()
            let t0 = ContinuousClock.now
            let beforeDispatches = RoutingCompute.current?.solver.submittedBatches ?? 0
            let beforeGpu = RoutingCompute.current?.gpuSeconds ?? 0
            defer {
                let dDisp = (RoutingCompute.current?.solver.submittedBatches ?? 0) - beforeDispatches
                let dGpu = (RoutingCompute.current?.gpuSeconds ?? 0) - beforeGpu
                profiler.record(
                    path: [stageName],
                    seconds: t0.duration(to: .now).seconds,
                    metalDispatches: max(0, dDisp),
                    metalGpuSeconds: max(0, dGpu)
                )
            }
            return try body()
        }
        let scope = LayoutStageScope(parent: parent, name: name(), from: from, to: to)
        scope.report(0)
        let t0 = profiler != nil ? ContinuousClock.now : nil
        let beforeDispatches = profiler != nil ? (RoutingCompute.current?.solver.submittedBatches ?? 0) : 0
        let beforeGpu = profiler != nil ? (RoutingCompute.current?.gpuSeconds ?? 0) : 0
        defer {
            if let profiler, let t0 {
                let dDisp = (RoutingCompute.current?.solver.submittedBatches ?? 0) - beforeDispatches
                let dGpu = (RoutingCompute.current?.gpuSeconds ?? 0) - beforeGpu
                profiler.record(
                    path: scope.stages,
                    seconds: t0.duration(to: .now).seconds,
                    metalDispatches: max(0, dDisp),
                    metalGpuSeconds: max(0, dGpu)
                )
            }
        }
        let value = try $current.withValue(scope, operation: body)
        scope.report(1)
        return value
    }

    @inline(__always)
    static func run<T>(
        _ name: @autoclosure () -> String,
        from: Double = 0,
        to: Double = 1,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let profiler = LayoutStageProfiler.current
        guard let parent = current else {
            guard let profiler else { return try await body() }
            let stageName = name()
            let t0 = ContinuousClock.now
            let beforeDispatches = RoutingCompute.current?.solver.submittedBatches ?? 0
            let beforeGpu = RoutingCompute.current?.gpuSeconds ?? 0
            defer {
                let dDisp = (RoutingCompute.current?.solver.submittedBatches ?? 0) - beforeDispatches
                let dGpu = (RoutingCompute.current?.gpuSeconds ?? 0) - beforeGpu
                profiler.record(
                    path: [stageName],
                    seconds: t0.duration(to: .now).seconds,
                    metalDispatches: max(0, dDisp),
                    metalGpuSeconds: max(0, dGpu)
                )
            }
            return try await body()
        }
        let scope = LayoutStageScope(parent: parent, name: name(), from: from, to: to)
        scope.report(0)
        let t0 = profiler != nil ? ContinuousClock.now : nil
        let beforeDispatches = profiler != nil ? (RoutingCompute.current?.solver.submittedBatches ?? 0) : 0
        let beforeGpu = profiler != nil ? (RoutingCompute.current?.gpuSeconds ?? 0) : 0
        defer {
            if let profiler, let t0 {
                let dDisp = (RoutingCompute.current?.solver.submittedBatches ?? 0) - beforeDispatches
                let dGpu = (RoutingCompute.current?.gpuSeconds ?? 0) - beforeGpu
                profiler.record(
                    path: scope.stages,
                    seconds: t0.duration(to: .now).seconds,
                    metalDispatches: max(0, dDisp),
                    metalGpuSeconds: max(0, dGpu)
                )
            }
        }
        let value = try await $current.withValue(scope) { try await body() }
        scope.report(1)
        return value
    }

    /// Runs item `index` of `count` equally weighted items as a child stage.
    @inline(__always)
    static func run<T>(
        _ name: @autoclosure () -> String,
        part index: Int,
        of count: Int,
        _ body: () throws -> T
    ) rethrows -> T {
        guard current != nil || LayoutStageProfiler.current != nil, count > 0 else { return try body() }
        return try run(name(), from: Double(index) / Double(count), to: Double(index + 1) / Double(count), body)
    }

    @inline(__always)
    static func run<T>(
        _ name: @autoclosure () -> String,
        part index: Int,
        of count: Int,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard current != nil || LayoutStageProfiler.current != nil, count > 0 else { return try await body() }
        return try await run(name(), from: Double(index) / Double(count), to: Double(index + 1) / Double(count), body)
    }

    /// Starts a named leaf stage that is reported through the returned handle rather than a task-local binding.
    /// For flat phases inside one function, where wrapping a block in `run` would change what `return` exits.
    @inline(__always)
    static func begin(_ name: @autoclosure () -> String, from: Double = 0, to: Double = 1) -> LayoutStageHandle {
        let profiler = LayoutStageProfiler.current
        guard let parent = current else {
            guard let profiler else { return LayoutStageHandle(scope: nil) }
            let stageName = name()
            return LayoutStageHandle(
                scope: nil,
                profiler: profiler,
                path: [stageName],
                start: ContinuousClock.now,
                beforeDispatches: RoutingCompute.current?.solver.submittedBatches ?? 0,
                beforeGpu: RoutingCompute.current?.gpuSeconds ?? 0
            )
        }
        let scope = LayoutStageScope(parent: parent, name: name(), from: from, to: to)
        scope.report(0)
        return LayoutStageHandle(
            scope: scope,
            profiler: profiler,
            path: scope.stages,
            start: profiler != nil ? ContinuousClock.now : nil,
            beforeDispatches: profiler != nil ? (RoutingCompute.current?.solver.submittedBatches ?? 0) : 0,
            beforeGpu: profiler != nil ? (RoutingCompute.current?.gpuSeconds ?? 0) : 0
        )
    }

    /// Reports `completed` of `total` units within the current stage. Place next to existing cancellation
    /// checks, never in innermost pair or force loops.
    @inline(__always)
    static func tick(_ completed: Int, of total: Int) {
        guard let scope = current, total > 0 else { return }
        scope.report(Double(completed) / Double(total))
    }

    /// Progress for loops without a known bound: approaches but never reaches the end of the stage.
    @inline(__always)
    static func tick(asymptotic step: Int, halfLife: Int) {
        guard let scope = current, halfLife > 0 else { return }
        scope.report(1 - pow(0.5, Double(step) / Double(halfLife)))
    }

    /// Normalized cumulative `(from, to)` ranges for weighted sibling stages.
    static func slices(_ weights: [Double]) -> [(from: Double, to: Double)] {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return weights.indices.map { _ in (0, 1) } }
        var start = 0.0
        return weights.map { weight in
            let end = start + max(0, weight) / total
            defer { start = end }
            return (start, end)
        }
    }

    static func slices(_ weights: Double...) -> [(from: Double, to: Double)] { slices(weights) }

    /// Captures the current stage so it can be re-bound on the far side of a queue hop or detached task,
    /// where task-locals are not inherited.
    static func capture() -> LayoutProgressContext {
        LayoutProgressContext(scope: current, profiler: LayoutStageProfiler.current)
    }
}

/// A leaf stage started with `LayoutStageScope.begin`. Nested work does not see it; it reports to the enclosing stage.
struct LayoutStageHandle {
    fileprivate let scope: LayoutStageScope?
    fileprivate var profiler: LayoutStageProfiler? = nil
    fileprivate var path: [String] = []
    fileprivate var start: ContinuousClock.Instant? = nil
    fileprivate var beforeDispatches: Int = 0
    fileprivate var beforeGpu: Double = 0

    @inline(__always)
    func tick(_ completed: Int, of total: Int) {
        guard let scope, total > 0 else { return }
        scope.report(Double(completed) / Double(total))
    }

    /// Marks the stage complete. Skipped on early returns, like a throwing `run`.
    @inline(__always)
    func end() {
        scope?.report(1)
        if let profiler, let start {
            let dDisp = (RoutingCompute.current?.solver.submittedBatches ?? 0) - beforeDispatches
            let dGpu = (RoutingCompute.current?.gpuSeconds ?? 0) - beforeGpu
            profiler.record(
                path: path,
                seconds: start.duration(to: .now).seconds,
                metalDispatches: max(0, dDisp),
                metalGpuSeconds: max(0, dGpu)
            )
        }
    }
}

struct LayoutProgressContext: Sendable {
    let scope: LayoutStageScope?
    let profiler: LayoutStageProfiler?

    init(scope: LayoutStageScope?, profiler: LayoutStageProfiler? = nil) {
        self.scope = scope
        self.profiler = profiler
    }

    func bind<T>(_ body: () throws -> T) rethrows -> T {
        try LayoutStageScope.$current.withValue(scope) {
            try LayoutStageProfiler.$current.withValue(profiler, operation: body)
        }
    }
}

/// Throttles, orders and clamps the progress of one observed run.
final class LayoutProgressSink: @unchecked Sendable {
    private let handler: @Sendable (LayoutProgress) -> Void
    private let interval: UInt64
    private let lock = NSLock()

    // Retained, not an ObjectIdentifier: a freed sibling's address can be reused by the next stage.
    private var reported = 0.0
    private var reportedAt: UInt64 = 0
    private var reportedScope: LayoutStageScope?
    private var finished = false

    /// Stage offers stay below 1 so that `finish` is the only report of exactly 1.
    private static let ceiling = 1.0.nextDown

    init(handler: @escaping @Sendable (LayoutProgress) -> Void, minimumInterval: Duration = .milliseconds(30)) {
        self.handler = handler
        let (seconds, attoseconds) = minimumInterval.components
        interval = UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds) / 1_000_000_000)
    }

    func offer(_ fraction: Double, scope: LayoutStageScope) {
        // Reports are lossy: a contended or reentrant offer is dropped rather than blocking layout work.
        // Holding the lock across the handler keeps deliveries ordered.
        guard lock.try() else { return }
        defer { lock.unlock() }
        let value = min(Self.ceiling, max(reported, fraction))
        guard !finished, value - reported >= 0.002 || scope !== reportedScope else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard reportedScope == nil || now &- reportedAt >= interval else { return }
        reported = value
        reportedAt = now
        reportedScope = scope
        handler(LayoutProgress(stages: scope.stages, fraction: value))
    }

    /// Emits the single final report of 1. Called only after the whole run succeeded.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        reportedScope = nil
        handler(LayoutProgress(stages: [], fraction: 1))
    }
}
