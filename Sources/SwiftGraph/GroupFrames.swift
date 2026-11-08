/// Insets in graph coordinates, independent of any UI framework.
public struct LayoutInsets: Hashable, Codable, Sendable {
    public var top: Float
    public var left: Float
    public var bottom: Float
    public var right: Float
    public init(top: Float, left: Float, bottom: Float, right: Float) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
    public init(_ value: Float = 20) { self.init(top: value, left: value, bottom: value, right: value) }
    @_disfavoredOverload
    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.init(top: Float(top), left: Float(left), bottom: Float(bottom), right: Float(right))
    }
    @_disfavoredOverload
    public init(_ value: Double) { self.init(Float(value)) }
}

/// A frame grows to contain its contents. Measure title text in the caller's renderer.
public struct GroupFrameOptions: Hashable, Codable, Sendable {
    public var padding: LayoutInsets
    public var headerSize: Size
    /// Gap between the bottom of the header band and the group's content. Ignored when the header has no height.
    public var headerSpacing: Float
    public var minimumSize: Size
    public init(padding: LayoutInsets = LayoutInsets(), headerSize: Size = Size(), headerSpacing: Float = 12,
                minimumSize: Size = Size()) {
        self.padding = padding; self.headerSize = headerSize; self.headerSpacing = headerSpacing; self.minimumSize = minimumSize
    }
    public init(from decoder: Decoder) throws {
        // Payloads written before `headerSpacing` existed still decode, with the default gap.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        padding = try c.decode(LayoutInsets.self, forKey: .padding)
        headerSize = try c.decode(Size.self, forKey: .headerSize)
        headerSpacing = try c.decodeIfPresent(Float.self, forKey: .headerSpacing) ?? 12
        minimumSize = try c.decode(Size.self, forKey: .minimumSize)
    }
    /// The vertical space the header occupies above the content: the band plus its trailing gap.
    var headerExtent: Float { headerSize.height > 0 ? headerSize.height + headerSpacing : 0 }
    func validate() throws {
        guard [padding.top, padding.left, padding.bottom, padding.right, headerSize.width, headerSize.height,
               headerSpacing, minimumSize.width, minimumSize.height].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw LayoutExecutionError.invalidInput("Frame dimensions and padding must be finite and nonnegative.")
        }
    }
}

public extension LayoutNode {
    /// The part of a group's header band that its title occupies: the band's leading `headerSize.width`
    /// (the whole band when no width was given). Routes must avoid this rectangle, but may cross the rest of the
    /// band, so edges can enter a group's first row from above instead of wrapping round through the side padding.
    var groupTitleBounds: Rect? {
        guard isGroup, let band = groupHeaderBounds, band.width > 0, band.height > 0 else { return nil }
        let titleWidth = groupFrame?.headerSize.width ?? 0
        return Rect(x: band.x, y: band.y, width: titleWidth > 0 ? min(band.width, titleWidth) : band.width, height: band.height)
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
