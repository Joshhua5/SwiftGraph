import Foundation

/// Aggregated wall-clock and Metal telemetry for a named layout or routing stage path.
public struct LayoutStageTiming: Sendable, Codable, Equatable {
    public var path: [String]
    public var callCount: Int = 0
    public var totalSeconds: Double = 0
    public var maxSingleSeconds: Double = 0
    public var metalDispatches: Int = 0
    public var metalGpuSeconds: Double = 0

    public init(
        path: [String],
        callCount: Int = 0,
        totalSeconds: Double = 0,
        maxSingleSeconds: Double = 0,
        metalDispatches: Int = 0,
        metalGpuSeconds: Double = 0
    ) {
        self.path = path
        self.callCount = callCount
        self.totalSeconds = totalSeconds
        self.maxSingleSeconds = maxSingleSeconds
        self.metalDispatches = metalDispatches
        self.metalGpuSeconds = metalGpuSeconds
    }
}
