/// Insets in graph coordinates, independent of any UI framework.
public struct LayoutInsets: Hashable, Codable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double
    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
    public init(_ value: Double = 20) { self.init(top: value, left: value, bottom: value, right: value) }
}

/// A frame grows to contain its contents. Measure title text in the caller's renderer.
public struct GroupFrameOptions: Hashable, Codable, Sendable {
    public var padding: LayoutInsets
    public var headerSize: Size
    public var minimumSize: Size
    public init(padding: LayoutInsets = LayoutInsets(), headerSize: Size = Size(), minimumSize: Size = Size()) {
        self.padding = padding; self.headerSize = headerSize; self.minimumSize = minimumSize
    }
    func validate() throws {
        guard [padding.top, padding.left, padding.bottom, padding.right, headerSize.width,
               headerSize.height, minimumSize.width, minimumSize.height].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw LayoutExecutionError.invalidInput("Frame dimensions and padding must be finite and nonnegative.")
        }
    }
}

public extension LayoutGraph {
    /// Creates and registers an empty group. A nil parent means the invisible root.
    @discardableResult func addGroup(id: String, parent: LayoutNode? = nil,
                                    frame: GroupFrameOptions = GroupFrameOptions()) throws -> LayoutNode {
        try frame.validate()
        let group = LayoutNode(id: id, width: 0, height: 0)
        group.isGroup = true; group.groupFrame = frame
        try addNode(group, to: parent)
        return group
    }

    /// Registers a new node, or reparents an existing member, without duplicating it.
    func addNode(_ node: LayoutNode, to parent: LayoutNode?) throws {
        let destination = parent ?? root
        let registered = nodes.contains(node)
        guard node !== root, destination.isGroup,
              Set(nodes).count == nodes.count,
              destination === root || nodes.contains(destination),
              registered || (node.parent == nil && node.children.isEmpty),
              node.parent == nil || node.parent === root || nodes.contains(node.parent!),
              node.children.allSatisfy({ nodes.contains($0) && $0.parent === node }) else {
            throw LayoutExecutionError.invalidInput("Groups and children must belong to this graph.")
        }
        var pending = [node], seen = Set<LayoutNode>()
        while let child = pending.popLast() {
            guard seen.insert(child).inserted, child !== destination else { throw GraphError.cyclicGroupHierarchy }
            pending.append(contentsOf: child.children)
        }
        if registered && node.parent === destination && destination.children.filter({ $0 === node }).count == 1 { return }
        if !registered { nodes.append(node) }
        node.parent?.children.removeAll { $0 === node }
        destination.children.removeAll { $0 === node }
        destination.children.append(node); node.parent = destination
    }

    func moveNode(_ node: LayoutNode, to parent: LayoutNode?) throws {
        guard nodes.contains(node) else { throw LayoutExecutionError.invalidInput("Only registered nodes can be moved.") }
        try addNode(node, to: parent)
    }
}
