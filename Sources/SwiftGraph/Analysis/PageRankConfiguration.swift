import Foundation

public struct PageRankConfiguration: Sendable {
    public var dampingFactor: Double = 0.85
    public var iterations: Int = 20

    /// Double-single GPU arithmetic keeps rank errors substantially below Float precision.
    public var maximumRankError: Double = 1e-10
    public var minimumMetalNodeCount: Int = 1_024

    public init() {}

    func validate() throws {
        guard dampingFactor.isFinite, (0...1).contains(dampingFactor), iterations >= 0,
            maximumRankError.isFinite, maximumRankError > 0, minimumMetalNodeCount >= 0
        else {
            throw LayoutExecutionError.invalidInput("Invalid PageRank configuration.")
        }
    }
}
