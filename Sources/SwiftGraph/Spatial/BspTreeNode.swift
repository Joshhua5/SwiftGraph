import Foundation

public final class BspTreeNode {
    public enum Axis: Sendable { case none, horizontal, vertical }

    public var bounds: Rect
    public var splitAxis: Axis = .none
    public var splitPosition: Float = 0
    public var left: BspTreeNode?
    public var right: BspTreeNode?
    public var containedNodes: [LayoutNode] = []
    public var isLeaf: Bool { left == nil && right == nil }

    public init(bounds: Rect) { self.bounds = bounds }
}
