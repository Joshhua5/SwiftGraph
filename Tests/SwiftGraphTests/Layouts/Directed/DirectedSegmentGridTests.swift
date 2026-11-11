import Testing
@testable import SwiftGraph

struct DirectedSegmentGridTests {
    private struct Visit: Hashable, Comparable {
        var owner: Int
        var ax: Float, ay: Float, bx: Float, by: Float

        static func < (lhs: Visit, rhs: Visit) -> Bool {
            (lhs.owner, lhs.ax, lhs.ay, lhs.bx, lhs.by) < (rhs.owner, rhs.ax, rhs.ay, rhs.bx, rhs.by)
        }
    }

    /// Deterministic orthogonal routes, some spanning many buckets and some degenerate.
    private struct Routes {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }

        mutating func route() -> [Point] {
            var point = Point(x: Float(next(800)) - 200, y: Float(next(800)) - 200)
            var path = [point]
            for step in 0..<(1 + next(6)) {
                let length = Float(next(5) == 0 ? 0 : next(300)) - 100
                point = step % 2 == 0 ? Point(x: point.x + length, y: point.y) : Point(x: point.x, y: point.y + length)
                path.append(point)
            }
            return path
        }
    }

    private func visits(
        _ grid: DirectedSegmentGrid,
        near query: DirectedGeometry.Segment,
        margin: Float
    ) -> [Visit] {
        var result: [Visit] = []
        grid.forEach(near: query, margin: margin) { owner, segment in
            result.append(Visit(owner: owner, ax: segment.a.x, ay: segment.a.y, bx: segment.b.x, by: segment.b.y))
        }
        return result
    }

    private func rebuilt(_ paths: [Int: [Point]]) -> DirectedSegmentGrid {
        let grid = DirectedSegmentGrid()
        for owner in paths.keys.sorted() { grid.insert(paths[owner]!, owner: owner) }
        return grid
    }

    private func expectEquivalent(
        _ grid: DirectedSegmentGrid,
        _ paths: [Int: [Point]],
        queries: inout Routes
    ) {
        let reference = rebuilt(paths)
        #expect(grid.segments.count == reference.segments.count)
        for _ in 0..<40 {
            let query = DirectedGeometry.segments(queries.route())[0]
            let margin = Float(queries.next(3)) * 10
            let found = visits(grid, near: query, margin: margin)
            #expect(Set(found).count == found.count, "each segment is visited once")
            #expect(found.sorted() == visits(reference, near: query, margin: margin).sorted())
        }
    }

    @Test func removingAndReinsertingOwnersMatchesAFullRebuild() {
        var routes = Routes(seed: 42)
        var paths: [Int: [Point]] = [:]
        let grid = DirectedSegmentGrid()
        for owner in 0..<60 {
            paths[owner] = routes.route()
            grid.insert(paths[owner]!, owner: owner)
        }
        expectEquivalent(grid, paths, queries: &routes)
        // The polishing pattern: take one route out, change it, put it back.
        for _ in 0..<200 {
            let owner = routes.next(60)
            grid.remove(owner: owner)
            paths[owner] = nil
            if routes.next(4) == 0 { expectEquivalent(grid, paths, queries: &routes) }
            if routes.next(5) != 0 {
                paths[owner] = routes.route()
                grid.insert(paths[owner]!, owner: owner)
            }
        }
        expectEquivalent(grid, paths, queries: &routes)
    }

    @Test func removingAnAbsentOwnerOrEveryOwnerLeavesAnEmptyIndex() {
        var routes = Routes(seed: 7)
        let grid = DirectedSegmentGrid()
        grid.remove(owner: 3)
        for owner in 0..<10 { grid.insert(routes.route(), owner: owner) }
        for owner in (0..<10).reversed() { grid.remove(owner: owner) }
        #expect(grid.segments.isEmpty)
        let query = DirectedGeometry.Segment(a: Point(x: -500, y: 0), b: Point(x: 900, y: 0))
        #expect(visits(grid, near: query, margin: 1000).isEmpty)
        grid.insert([Point(x: 0, y: 0), Point(x: 10, y: 0)], owner: 4)
        #expect(visits(grid, near: query, margin: 10).map(\.owner) == [4])
    }
}
