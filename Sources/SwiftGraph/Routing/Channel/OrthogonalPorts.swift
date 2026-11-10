import Foundation

/// Side choice and boundary ports shared by the orthogonal routers.
enum OrthogonalPorts {
    static func isVertical(_ side: PortConstraint) -> Bool { side == .top || side == .bottom }

    static func opposite(_ side: PortConstraint) -> PortConstraint {
        switch side {
        case .top: .bottom
        case .bottom: .top
        case .left: .right
        case .right: .left
        case .none: .none
        }
    }

    /// Dominant direction of travel along the edges, by centre displacement; `direction` is nil unless most of it
    /// points one way.
    static func flow(_ graph: LayoutGraph) -> (vertical: Bool, direction: Point?) {
        var sx: Float = 0
        var sy: Float = 0
        var ax: Float = 0
        var ay: Float = 0
        for e in graph.edges where e.source !== e.target {
            let d = e.target.center - e.source.center
            sx += d.x
            sy += d.y
            ax += abs(d.x)
            ay += abs(d.y)
        }
        let vertical = ay >= ax
        if vertical { return (true, ay > 0 && abs(sy) >= ay / 2 ? Point(x: 0, y: sy > 0 ? 1 : -1) : nil) }
        return (false, ax > 0 && abs(sx) >= ax / 2 ? Point(x: sx > 0 ? 1 : -1, y: 0) : nil)
    }

    /// The sides an edge to `other` may use, facing sides first; a tie between the two axes follows the layout flow.
    static func ranked(
        _ node: LayoutNode,
        other: LayoutNode,
        active: PortConstraint,
        candidates: [PortConstraint],
        vertical flowVertical: Bool
    ) -> [PortConstraint] {
        if active != .none { return [active] }
        let r = node.bounds
        let o = other.bounds
        let gapX = max(o.left - r.right, r.left - o.right)
        let gapY = max(o.top - r.bottom, r.top - o.bottom)
        // Ties are decided with a half-unit tolerance so GPU-rounded layouts choose the same sides.
        let horizontal = abs(gapX - gapY) > 0.5 ? gapX > gapY : !flowVertical
        let h: PortConstraint = o.center.x < r.center.x - 0.5 ? .left : .right
        let v: PortConstraint = o.center.y < r.center.y - 0.5 ? .top : .bottom
        let sides = horizontal ? [h, v, opposite(v), opposite(h)] : [v, h, opposite(h), opposite(v)]
        let allowed = candidates.filter { $0 != .none }
        return allowed.isEmpty ? sides : sides.filter(allowed.contains)
    }

    /// The side's point on the node boundary, level with the other node where they overlap, kept off the corners.
    static func point(_ node: LayoutNode, side: PortConstraint, toward other: Rect) -> Point {
        let r = node.bounds
        let vertical = isVertical(side)
        let lo = vertical ? r.left : r.top
        let hi = vertical ? r.right : r.bottom
        let inset = min(10, (hi - lo) / 4)
        let otherLo = vertical ? other.left : other.top
        let otherHi = vertical ? other.right : other.bottom
        let value =
            max(lo, otherLo) < min(hi, otherHi) ? (max(lo, otherLo) + min(hi, otherHi)) / 2 : (otherLo + otherHi) / 2
        let along = min(max(value, lo + inset), hi - inset)
        switch side {
        case .top: return Point(x: along, y: r.top)
        case .bottom: return Point(x: along, y: r.bottom)
        case .left: return Point(x: r.left, y: along)
        default: return Point(x: r.right, y: along)
        }
    }
}
