import Foundation

public struct Point: Hashable, Codable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float = 0, y: Float = 0) {
        self.x = x
        self.y = y
    }

    @_disfavoredOverload
    public init(x: Double, y: Double) {
        self.x = Float(x)
        self.y = Float(y)
    }

    public static let zero = Point()
    public var lengthSquared: Float { x * x + y * y }
    public var length: Float { sqrt(lengthSquared) }

    public static func + (a: Self, b: Self) -> Self { Point(x: a.x + b.x, y: a.y + b.y) }

    public static func - (a: Self, b: Self) -> Self { Point(x: a.x - b.x, y: a.y - b.y) }

    public static func * (a: Self, s: Float) -> Self { Point(x: a.x * s, y: a.y * s) }

    public static func / (a: Self, s: Float) -> Self { Point(x: a.x / s, y: a.y / s) }

    @_disfavoredOverload
    public static func * (a: Self, s: Double) -> Self { Point(x: a.x * Float(s), y: a.y * Float(s)) }

    @_disfavoredOverload
    public static func / (a: Self, s: Double) -> Self { Point(x: a.x / Float(s), y: a.y / Float(s)) }
}
