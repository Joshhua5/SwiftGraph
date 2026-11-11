import Foundation

/// The direction a layered drawing's ranks follow. `LayeredRouter` plans in a left-to-right frame, where ranks are
/// distinct x coordinates; any other flow is transposed into that frame for the duration of routing and back again,
/// so every flow gets exactly the same planning.
enum LayeredFlow: Sendable {
    /// Ranks are columns and edges run left to right (the directed layout).
    case leftToRight
    /// Ranks are rows and edges run top to bottom (the hierarchical and swimlane layouts).
    case topToBottom

    /// Runs `body` with `nodes` and `edges` (bounds, paths and port constraints) in the router's left-to-right
    /// frame, then restores the flow's frame, also when `body` throws. Transposing swaps coordinates, so it is exact.
    func inRouterFrame<T>(nodes: [LayoutNode], edges: [LayoutEdge], _ body: () throws -> T) rethrows -> T {
        guard self == .topToBottom else { return try body() }
        Self.transpose(nodes: nodes, edges: edges)
        defer { Self.transpose(nodes: nodes, edges: edges) }
        return try body()
    }

    /// `paths` in the router's left-to-right frame.
    func inRouterFrame(_ paths: [Int: [Point]]) -> [Int: [Point]] {
        guard self == .topToBottom else { return paths }
        return paths.mapValues { $0.map(Self.transposed) }
    }

    /// Reflects the geometry in the line y = x. Applying it twice restores the input.
    private static func transpose(nodes: [LayoutNode], edges: [LayoutEdge]) {
        for node in nodes { node.bounds = Rect(x: node.y, y: node.x, width: node.height, height: node.width) }
        for edge in edges {
            edge.path = edge.path.map(transposed)
            edge.sourcePort = transposed(edge.sourcePort)
            edge.targetPort = transposed(edge.targetPort)
        }
    }

    private static func transposed(_ point: Point) -> Point { Point(x: point.y, y: point.x) }

    private static func transposed(_ side: PortConstraint) -> PortConstraint {
        switch side {
        case .none: .none
        case .top: .left
        case .left: .top
        case .bottom: .right
        case .right: .bottom
        }
    }
}
