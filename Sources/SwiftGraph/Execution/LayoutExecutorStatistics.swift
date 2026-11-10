import Foundation

public struct LayoutExecutorStatistics: Sendable {
    public let pipelineBuilds: Int
    public let bufferAllocations: Int
    public let bufferReuses: Int
    public let submittedBatches: Int
    public let completedBatches: Int
    public let cachedBufferBytes: Int
}
