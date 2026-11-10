import Foundation

/// Where a layout run currently is. Delivered on arbitrary threads, throttled to roughly 30 updates per second.
public struct LayoutProgress: Sendable, Equatable {
    /// Stage names, outermost first, e.g. `["Organic", "Candidate 3/12", "Force simulation"]`.
    public let stages: [String]

    /// Overall completion in 0...1. It never decreases during one run, and a successful run ends at exactly 1.
    public let fraction: Double
    public var stage: String? { stages.last }

    public init(stages: [String], fraction: Double) {
        self.stages = stages
        self.fraction = fraction
    }
}

/// Reports progress for layout work run directly inside `operation`, without a `LayoutBuilder`.
/// The handler is called on background threads; it must return quickly and must not start layout work.
/// Synchronous `applyLayout` calls made outside the current task (for example on a caller-owned queue) report nothing.
public func withLayoutProgress<T>(
    _ handler: @escaping @Sendable (LayoutProgress) -> Void,
    operation: () async throws -> T
) async rethrows -> T {
    try await withLayoutProgress(LayoutProgressSink(handler: handler), operation: operation)
}

func withLayoutProgress<T>(_ sink: LayoutProgressSink, operation: () async throws -> T) async rethrows -> T {
    let value = try await LayoutStageScope.$current.withValue(LayoutStageScope(sink: sink)) { try await operation() }
    sink.finish()
    return value
}
