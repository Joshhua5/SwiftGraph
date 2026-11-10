import Foundation

public struct BarycenterLayoutConfiguration: Sendable {
    public var iterations = 3
    public var minSpacing: Float = 10

    public init() {}

    func validate() throws {
        guard iterations >= 0, iterations < Int.max / 16, minSpacing.isFinite, minSpacing >= 0 else {
            throw LayoutExecutionError.invalidInput("Barycenter iterations and spacing must be finite and nonnegative.")
        }
    }
}
