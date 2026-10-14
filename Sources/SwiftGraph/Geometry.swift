import Foundation

public struct Point: Hashable, Codable, Sendable {
    public var x: Float
    public var y: Float
    public init(x: Float = 0, y: Float = 0) { self.x = x; self.y = y }
    @_disfavoredOverload
    public init(x: Double, y: Double) { self.x = Float(x); self.y = Float(y) }
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

public struct Size: Hashable, Codable, Sendable {
    public var width: Float
    public var height: Float
    public init(width: Float = 0, height: Float = 0) { self.width = width; self.height = height }
    @_disfavoredOverload
    public init(width: Double, height: Double) { self.width = Float(width); self.height = Float(height) }
}

public struct Rect: Hashable, Codable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float
    public init(x: Float = 0, y: Float = 0, width: Float = 0, height: Float = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    @_disfavoredOverload
    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = Float(x); self.y = Float(y); self.width = Float(width); self.height = Float(height)
    }
    public init(location: Point, size: Size) {
        self.init(x: location.x, y: location.y, width: size.width, height: size.height)
    }
    public var left: Float { x }
    public var right: Float { x + width }
    public var top: Float { y }
    public var bottom: Float { y + height }
    public var center: Point { Point(x: x + width / 2, y: y + height / 2) }
    public var size: Size { Size(width: width, height: height) }
    public func contains(_ p: Point) -> Bool { p.x >= left && p.x <= right && p.y >= top && p.y <= bottom }
    public func intersects(_ other: Rect) -> Bool {
        left < other.right && right > other.left && top < other.bottom && bottom > other.top
    }
    /// Closed segment/rectangle intersection, including collinear boundary segments.
    public func intersectsLine(_ a: Point, _ b: Point) -> Bool {
        var lo: Float = 0.0, hi: Float = 1.0
        for (origin, delta, low, high) in [(a.x, b.x - a.x, left, right), (a.y, b.y - a.y, top, bottom)] {
            if abs(delta) < 1e-6 {
                if origin < low || origin > high { return false }
            } else {
                let t1 = (low - origin) / delta, t2 = (high - origin) / delta
                lo = max(lo, min(t1, t2)); hi = min(hi, max(t1, t2))
                if lo > hi { return false }
            }
        }
        return true
    }
    public func inflated(by amount: Float) -> Rect {
        Rect(x: x - amount, y: y - amount, width: width + 2 * amount, height: height + 2 * amount)
    }
    @_disfavoredOverload
    public func inflated(by amount: Double) -> Rect {
        inflated(by: Float(amount))
    }
    public func translated(by offset: Point) -> Rect {
        Rect(x: x + offset.x, y: y + offset.y, width: width, height: height)
    }
    public func union(_ other: Rect) -> Rect {
        Rect(x: min(left, other.left), y: min(top, other.top),
             width: max(right, other.right) - min(left, other.left),
             height: max(bottom, other.bottom) - min(top, other.top))
    }
}
