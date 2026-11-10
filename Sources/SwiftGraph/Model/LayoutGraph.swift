public final class LayoutGraph {
    public var nodes: [LayoutNode] = []
    public var edges: [LayoutEdge] = []
    public let root: LayoutNode

    public init() {
        root = LayoutNode(id: "ROOT", width: 0, height: 0)
        root.isGroup = true
    }

    public func addNode(_ node: LayoutNode) {
        nodes.append(node)
        if node.parent == nil {
            root.children.append(node)
            node.parent = root
        }
    }

    public func addEdge(_ edge: LayoutEdge) { edges.append(edge) }

    /// Temporary graph membership must never reparent nodes in the caller's hierarchy.
    public func addNodeDetached(_ node: LayoutNode) {
        nodes.append(node)
        root.children.append(node)
    }

    public var bounds: Rect { enclosingBounds(nodes) }
}
