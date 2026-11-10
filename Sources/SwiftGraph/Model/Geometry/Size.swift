import Foundation

public struct Size: Hashable, Codable, Sendable {
    public var width: Float
    public var height: Float

    public init(width: Float = 0, height: Float = 0) {
        self.width = width
        self.height = height
    }

    @_disfavoredOverload
    public init(width: Double, height: Double) {
        self.width = Float(width)
        self.height = Float(height)
    }
}
