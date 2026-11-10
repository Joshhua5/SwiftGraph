/// Insets in graph coordinates, independent of any UI framework.
public struct LayoutInsets: Hashable, Codable, Sendable {
    public var top: Float
    public var left: Float
    public var bottom: Float
    public var right: Float

    public init(top: Float, left: Float, bottom: Float, right: Float) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public init(_ value: Float = 20) { self.init(top: value, left: value, bottom: value, right: value) }

    @_disfavoredOverload
    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.init(top: Float(top), left: Float(left), bottom: Float(bottom), right: Float(right))
    }

    @_disfavoredOverload
    public init(_ value: Double) { self.init(Float(value)) }
}
