import Foundation

/// Where one end of an edge meets its node: the node side, and the point on it.
public struct EdgePort: Equatable, Sendable {
    public var side: PortConstraint
    public var point: Point

    public init(side: PortConstraint, point: Point) {
        self.side = side
        self.point = point
    }

    /// The point `distance` straight out from the side.
    public func stub(_ distance: Float) -> Point { point + PortAssignment.normal(side) * distance }
}

/// The ports `PortAssignment` chose, by edge. Edges it gave no ports (self-loops, overlapping ends) have none.
public struct AssignedPorts {
    private var ends: [ObjectIdentifier: (source: EdgePort?, target: EdgePort?)] = [:]

    public init() {}

    /// Whether no edge has a port.
    public var isEmpty: Bool { ends.isEmpty }

    /// The port where `edge` leaves its source.
    public func source(of edge: LayoutEdge) -> EdgePort? { ends[ObjectIdentifier(edge)]?.source }

    /// The port where `edge` enters its target.
    public func target(of edge: LayoutEdge) -> EdgePort? { ends[ObjectIdentifier(edge)]?.target }

    /// The port at `node`'s end of `edge`; for an edge joining a node to itself, its source end.
    public func port(of edge: LayoutEdge, at node: LayoutNode) -> EdgePort? {
        node === edge.source ? source(of: edge) : node === edge.target ? target(of: edge) : nil
    }

    mutating func set(_ port: EdgePort, for edge: LayoutEdge, isSource: Bool) {
        var pair = ends[ObjectIdentifier(edge)] ?? (nil, nil)
        if isSource { pair.source = port } else { pair.target = port }
        ends[ObjectIdentifier(edge)] = pair
    }
}
