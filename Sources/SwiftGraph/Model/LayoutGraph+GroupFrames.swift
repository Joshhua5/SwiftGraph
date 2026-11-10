extension LayoutGraph {
    /// Creates and registers an empty group. A nil parent means the invisible root.
    @discardableResult public func addGroup(
        id: String,
        parent: LayoutNode? = nil,
        frame: GroupFrameOptions = GroupFrameOptions()
    ) throws -> LayoutNode {
        try frame.validate()
        let group = LayoutNode(id: id, width: 0, height: 0)
        group.isGroup = true
        group.groupFrame = frame
        try addNode(group, to: parent)
        return group
    }

    /// Registers a new node, or reparents an existing member, without duplicating it.
    public func addNode(_ node: LayoutNode, to parent: LayoutNode?) throws {
        let destination = parent ?? root
        let registered = nodes.contains(node)
        guard node !== root, destination.isGroup,
            Set(nodes).count == nodes.count,
            destination === root || nodes.contains(destination),
            registered || (node.parent == nil && node.children.isEmpty),
            node.parent.map { $0 === root || nodes.contains($0) } ?? true,
            node.children.allSatisfy({ nodes.contains($0) && $0.parent === node })
        else {
            throw LayoutExecutionError.invalidInput("Groups and children must belong to this graph.")
        }
        var pending = [node]
        var seen = Set<LayoutNode>()
        while let child = pending.popLast() {
            guard seen.insert(child).inserted, child !== destination else { throw GraphError.cyclicGroupHierarchy }
            pending.append(contentsOf: child.children)
        }
        if registered && node.parent === destination && destination.children.filter({ $0 === node }).count == 1 {
            return
        }
        if !registered { nodes.append(node) }
        node.parent?.children.removeAll { $0 === node }
        destination.children.removeAll { $0 === node }
        destination.children.append(node)
        node.parent = destination
    }

    public func moveNode(_ node: LayoutNode, to parent: LayoutNode?) throws {
        guard nodes.contains(node) else {
            throw LayoutExecutionError.invalidInput("Only registered nodes can be moved.")
        }
        try addNode(node, to: parent)
    }
}
