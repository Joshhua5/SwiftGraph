import Foundation

public struct ClusterAnalysisConfiguration: Sendable {
    /// The algorithm retains the reference's fixed 20 passes and seeded in-place update order.
    public var minimumMetalNodeCount: Int = 1_024

    public init() {}

    func validate() throws {
        guard minimumMetalNodeCount >= 0 else {
            throw LayoutExecutionError.invalidInput("Invalid cluster selection threshold.")
        }
    }
}
