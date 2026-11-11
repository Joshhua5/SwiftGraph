import Foundation

/// The free gap across an axis-aligned stretch: how far a route running along it can move sideways before it meets a
/// node. Leaves and group titles are solid; a group is solid from outside and, for a stretch inside it, its border is
/// a wall. Gaps wider than `reach` either side count as open.
struct CorridorWalls {
    struct Gap {
        var low: Float
        var high: Float

        var isOpen: Bool { !low.isFinite || !high.isFinite }
        var width: Float { high - low }
    }

    private struct Wall {
        var rect: Rect
        var isContainer: Bool
    }

    let reach: Float
    private let tree: QuadTree<Int>
    private let walls: [Wall]
    private static let tolerance: Float = 1e-3

    /// Walls for routing over `nodes`: leaves and titles are solid, groups are containers.
    init(_ nodes: [LayoutNode], reach: Float) {
        var walls: [Wall] = []
        for node in nodes where node.bounds.width > 0 && node.bounds.height > 0 {
            walls.append(Wall(rect: node.bounds, isContainer: node.isGroup))
            if let title = node.groupTitleBounds, title.width > 0, title.height > 0 {
                walls.append(Wall(rect: title, isContainer: false))
            }
        }
        self.reach = reach
        self.walls = walls
        let bounds = walls.first.map { first in walls.dropFirst().reduce(first.rect) { $0.union($1.rect) } } ?? Rect()
        tree = QuadTree(bounds: bounds.inflated(by: 1))
        for (index, wall) in walls.enumerated() { tree.insert(bounds: wall.rect, item: index) }
    }

    /// The gap across a stretch at `at` (x for a vertical stretch, y for a horizontal one) that runs from `low` to
    /// `high` along its axis. A node that only touches the stretch's ends, such as the node a route leaves, is not a
    /// wall. A side with no wall within `reach` is infinite.
    func gap(vertical: Bool, at: Float, from low: Float, to high: Float) -> Gap {
        let along = (low + Self.tolerance, high - Self.tolerance)
        guard along.0 < along.1 else { return Gap(low: -.infinity, high: .infinity) }
        let strip =
            vertical
            ? Rect(x: at - reach, y: along.0, width: 2 * reach, height: along.1 - along.0)
            : Rect(x: along.0, y: at - reach, width: along.1 - along.0, height: 2 * reach)
        var result = Gap(low: -.infinity, high: .infinity)
        tree.forEach(intersecting: strip.inflated(by: Self.tolerance)) { _, index in
            let wall = walls[index]
            let r = wall.rect
            let (alongLow, alongHigh) = vertical ? (r.top, r.bottom) : (r.left, r.right)
            let (acrossLow, acrossHigh) = vertical ? (r.left, r.right) : (r.top, r.bottom)
            guard alongLow < along.1, alongHigh > along.0 else { return }
            if acrossHigh <= at + Self.tolerance {
                result.low = max(result.low, acrossHigh)
            } else if acrossLow >= at - Self.tolerance {
                result.high = min(result.high, acrossLow)
            } else if wall.isContainer, alongLow <= low + Self.tolerance, alongHigh >= high - Self.tolerance {
                // Inside a group: its border keeps the stretch in.
                result.low = max(result.low, acrossLow)
                result.high = min(result.high, acrossHigh)
            }
        }
        return result
    }
}
