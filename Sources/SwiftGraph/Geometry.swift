import Foundation

public struct Point: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
    public static let zero = Point()
    public var lengthSquared: Double { x * x + y * y }
    public var length: Double { sqrt(lengthSquared) }
    public static func + (a: Self, b: Self) -> Self { Point(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Self, b: Self) -> Self { Point(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: Self, s: Double) -> Self { Point(x: a.x * s, y: a.y * s) }
    public static func / (a: Self, s: Double) -> Self { Point(x: a.x / s, y: a.y / s) }
}

public struct Size: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double = 0, height: Double = 0) { self.width = width; self.height = height }
}

public struct Rect: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(location: Point, size: Size) {
        self.init(x: location.x, y: location.y, width: size.width, height: size.height)
    }
    public var left: Double { x }
    public var right: Double { x + width }
    public var top: Double { y }
    public var bottom: Double { y + height }
    public var center: Point { Point(x: x + width / 2, y: y + height / 2) }
    public var size: Size { Size(width: width, height: height) }
    public func contains(_ p: Point) -> Bool { p.x >= left && p.x <= right && p.y >= top && p.y <= bottom }
    public func intersects(_ other: Rect) -> Bool {
        left < other.right && right > other.left && top < other.bottom && bottom > other.top
    }
    /// Closed segment/rectangle intersection, including collinear boundary segments.
    public func intersectsLine(_ a: Point, _ b: Point) -> Bool {
        var lo = 0.0, hi = 1.0
        for (origin, delta, low, high) in [(a.x, b.x - a.x, left, right), (a.y, b.y - a.y, top, bottom)] {
            if abs(delta) < 1e-12 {
                if origin < low || origin > high { return false }
            } else {
                let t1 = (low - origin) / delta, t2 = (high - origin) / delta
                lo = max(lo, min(t1, t2)); hi = min(hi, max(t1, t2))
                if lo > hi { return false }
            }
        }
        return true
    }
    public func inflated(by amount: Double) -> Rect {
        Rect(x: x - amount, y: y - amount, width: width + 2 * amount, height: height + 2 * amount)
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
