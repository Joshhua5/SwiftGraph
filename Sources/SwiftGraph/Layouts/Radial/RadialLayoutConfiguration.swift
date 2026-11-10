import Foundation

public struct RadialLayoutConfiguration: Sendable {
    /// Minimum spacing between rings (the star's minimum radius).
    public var spacing: Float

    public init(spacing: Float = 100) { self.spacing = spacing }

    func validate() throws {
        guard spacing.isFinite, spacing >= 0 else {
            throw LayoutExecutionError.invalidInput("Radial spacing must be finite and nonnegative.")
        }
    }
}
