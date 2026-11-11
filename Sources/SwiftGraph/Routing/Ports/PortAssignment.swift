import Foundation

/// Decides where every edge end meets its node before any route is searched: a side, and a point on that side.
///
/// This is the one port model the stock routers share. Port constraints and candidate lists choose the side when an
/// edge has them; otherwise the side faces the other end (orthogonal styles) or is the side the line between the two
/// centres leaves by (other styles). On each side the ends are ordered by where they are headed and spread at least
/// `edgeSpacing` apart, kept off the corners by the shared inset rule (`span(of:side:inset:)`). The polyline router
/// searches from the assigned points; the channel router ranks the assigned side first and aims at its point. Finishing
/// stages (`EdgeSeparator`, `PortDistributor`) keep the same inset and may reorder ends within a side afterwards, but
/// never move one to another side.
///
/// An edge whose end nodes overlap (including a node and a group containing it) and a self-loop get no ports: the
/// router keeps its own handling for them.
public struct PortAssignment {
    /// Least distance of a port from a corner of its side, on sides at least four times as long.
    public static let defaultInset: Float = 10

    /// Least distance of a port from a corner; a side shorter than four insets keeps a quarter of its length clear.
    public var inset: Float

    /// Least gap between neighbouring ports on one side, where the side is long enough to hold it.
    public var edgeSpacing: Float

    public init(inset: Float = defaultInset, edgeSpacing: Float = 10) {
        self.inset = inset
        self.edgeSpacing = edgeSpacing
    }

    // MARK: - Shared inset rule

    /// The stretch of a node side a port may use, as coordinates along the side (x for top and bottom, y for left and
    /// right): the side less `inset` at each end, or less a quarter of its length when it is shorter than four insets.
    public static func span(
        of rect: Rect,
        side: PortConstraint,
        inset: Float = defaultInset
    ) -> (low: Float, high: Float) {
        let horizontal = side == .top || side == .bottom
        let low = horizontal ? rect.left : rect.top
        let high = horizontal ? rect.right : rect.bottom
        let clear = max(0, min(inset, (high - low) / 4))
        return (low + clear, high - clear)
    }

    // MARK: - Assignment

    /// Ports for every edge of `graph` that can have them.
    ///
    /// - Parameters:
    ///   - graph: The laid-out graph; nothing on it is changed.
    ///   - style: The geometry the routes will have. `.orthogonal` chooses the side facing the other end and aims the
    ///     port level with it; other styles take the side the centre-to-centre line leaves by, at that crossing.
    public func assign(_ graph: LayoutGraph, style: RouteStyle) -> AssignedPorts {
        let vertical = OrthogonalPorts.flow(graph).vertical
        var sides: [SideKey: [End]] = [:]
        var keys: [SideKey] = []
        for (index, edge) in graph.edges.enumerated() where Self.hasPorts(edge) {
            for isSource in [true, false] {
                let node = isSource ? edge.source : edge.target
                let other = isSource ? edge.target : edge.source
                let side = Self.side(
                    node,
                    other: other,
                    active: isSource ? edge.sourcePort : edge.targetPort,
                    candidates: isSource ? edge.sourcePortCandidates : edge.targetPortCandidates,
                    style: style,
                    vertical: vertical
                )
                let key = SideKey(node: ObjectIdentifier(node), side: side)
                if sides[key] == nil { keys.append(key) }
                sides[key, default: []]
                    .append(
                        End(
                            edge: edge,
                            index: index,
                            isSource: isSource,
                            wanted: Self.wanted(node, side: side, other: other, style: style, inset: inset),
                            tie: Self.tie(node.bounds, side: side, other: other.bounds)
                        )
                    )
            }
        }
        var result = AssignedPorts()
        for key in keys {
            let ends = sides[required: key]
                .sorted {
                    ($0.wanted, $0.tie, $0.index, $0.isSource ? 0 : 1) < (
                        $1.wanted, $1.tie, $1.index, $1.isSource ? 0 : 1
                    )
                }
            let node = ends[0].isSource ? ends[0].edge.source : ends[0].edge.target
            let along = spread(ends.map(\.wanted), within: Self.span(of: node.bounds, side: key.side, inset: inset))
            for (end, value) in zip(ends, along) {
                let port = EdgePort(side: key.side, point: Self.point(node.bounds, side: key.side, along: value))
                result.set(port, for: end.edge, isSource: end.isSource)
            }
        }
        return result
    }

    // MARK: - Private helpers

    private struct SideKey: Hashable {
        var node: ObjectIdentifier
        var side: PortConstraint
    }

    private struct End {
        var edge: LayoutEdge
        var index: Int
        var isSource: Bool
        var wanted: Float
        var tie: Float
    }

    /// Ports need two separate nodes with area: overlapping or nested ends and self-loops are left to the router.
    private static func hasPorts(_ edge: LayoutEdge) -> Bool {
        let a = edge.source.bounds
        let b = edge.target.bounds
        return edge.source !== edge.target && a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0
            && !a.intersects(b)
    }

    /// Ordered positions as near their wanted values as `edgeSpacing` allows, inside the span; on a side too short for
    /// the spacing the ends share it evenly. The least-squares fit is the one the directed router uses for its ports.
    private func spread(_ wanted: [Float], within span: (low: Float, high: Float)) -> [Float] {
        let count = wanted.count
        let clamped = wanted.map { min(max($0, span.low), span.high) }
        guard count > 1 else { return clamped }
        let step = min(edgeSpacing, max(0, span.high - span.low) / Float(count - 1))
        let fit = isotonicFit(
            clamped.enumerated().map { $1 - Float($0) * step },
            weights: Array(repeating: 1, count: count)
        )
        let last = span.high - Float(count - 1) * step
        return fit.enumerated().map { min(max($1, span.low), max(span.low, last)) + Float($0) * step }
    }

    private static func side(
        _ node: LayoutNode,
        other: LayoutNode,
        active: PortConstraint,
        candidates: [PortConstraint],
        style: RouteStyle,
        vertical: Bool
    ) -> PortConstraint {
        if active != .none { return active }
        let allowed = candidates.filter { $0 != .none }
        if style == .orthogonal {
            let ranked = OrthogonalPorts.ranked(
                node,
                other: other,
                active: .none,
                candidates: allowed,
                vertical: vertical
            )
            return ranked.first ?? allowed[0]
        }
        let d = other.center - node.center
        let r = node.bounds
        // Equal scores keep the listed order, so the choice never depends on the sort.
        let order = [PortConstraint.top, .bottom, .left, .right].enumerated()
            .sorted { (-score($0.element, d, r), $0.offset) < (-score($1.element, d, r), $1.offset) }
            .map(\.element)
        return order.first { allowed.isEmpty || allowed.contains($0) } ?? .right
    }

    /// How squarely the centre-to-centre line leaves through `side`: the side it crosses scores highest.
    private static func score(_ side: PortConstraint, _ d: Point, _ r: Rect) -> Float {
        let normal = normal(side)
        // Divided by the node's extent across the side, so the side the line actually crosses wins on a non-square node.
        let scale = side == .top || side == .bottom ? r.height : r.width
        return (normal.x * d.x + normal.y * d.y) / max(scale, 1e-6)
    }

    /// The coordinate along `side` the end would take alone: level with the other node for orthogonal routes, where
    /// the centre-to-centre line leaves the node for other styles.
    private static func wanted(
        _ node: LayoutNode,
        side: PortConstraint,
        other: LayoutNode,
        style: RouteStyle,
        inset: Float
    ) -> Float {
        let horizontal = side == .top || side == .bottom
        let r = node.bounds
        if style != .orthogonal {
            let d = other.center - r.center
            let reach = horizontal ? abs(d.y) : abs(d.x)
            let half = horizontal ? r.height / 2 : r.width / 2
            // Only where the line leaves through this side; a constrained side keeps the orthogonal aim.
            if reach > 1e-6 && score(side, d, r) > 0 {
                let t = half / reach
                let exit = r.center + d * t
                return horizontal ? exit.x : exit.y
            }
        }
        let p = OrthogonalPorts.point(node, side: side, toward: other.bounds, inset: inset)
        return horizontal ? p.x : p.y
    }

    /// Breaks ties between ends wanting the same point (most often clamped at a corner): the end that turns off soonest
    /// sits nearest the corner it heads past, so it does not cross the others.
    private static func tie(_ r: Rect, side: PortConstraint, other: Rect) -> Float {
        let horizontal = side == .top || side == .bottom
        let along = horizontal ? other.center.x - r.center.x : other.center.y - r.center.y
        let depth = horizontal ? abs(other.center.y - r.center.y) : abs(other.center.x - r.center.x)
        return along < 0 ? depth : -depth
    }

    static func normal(_ side: PortConstraint) -> Point {
        switch side {
        case .top: Point(x: 0, y: -1)
        case .bottom: Point(x: 0, y: 1)
        case .left: Point(x: -1, y: 0)
        case .right: Point(x: 1, y: 0)
        case .none: Point(x: 0, y: 0)
        }
    }

    private static func point(_ r: Rect, side: PortConstraint, along value: Float) -> Point {
        switch side {
        case .top: Point(x: value, y: r.top)
        case .bottom: Point(x: value, y: r.bottom)
        case .left: Point(x: r.left, y: value)
        case .right, .none: Point(x: r.right, y: value)
        }
    }
}
