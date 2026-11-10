public final class LayoutEdge: Hashable {
    public let source: LayoutNode
    public let target: LayoutNode
    public var data: Any?
    public var path: [Point] = []
    public var labelBounds = Rect()
    public var sourcePort: PortConstraint = .none
    public var targetPort: PortConstraint = .none
    public var sourcePortCandidates: [PortConstraint] = []
    public var targetPortCandidates: [PortConstraint] = []

    public init(source: LayoutNode, target: LayoutNode, data: Any? = nil) {
        self.source = source
        self.target = target
        self.data = data
    }

    public static func == (a: LayoutEdge, b: LayoutEdge) -> Bool { a === b }

    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
