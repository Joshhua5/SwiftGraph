import Testing

@testable import SwiftGraph

struct DirectedObstacleIndexTests {
    private struct Random {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }

        mutating func coordinate() -> Float { Float(next(1_600)) / 2 - 200 }
    }

    /// Rank columns as the layered placement produces them, plus scattered and overlapping clutter
    /// as incremental placement can leave; some rectangles share or touch edges.
    private func rects(_ random: inout Random) -> [Rect] {
        var result: [Rect] = []
        for column in 0..<5 {
            let center = Float(column) * 160
            var y: Float = -100
            for _ in 0..<(2 + random.next(5)) {
                let width = Float(40 + random.next(4) * 20)
                let height = Float(20 + random.next(3) * 10)
                result.append(Rect(x: center - width / 2, y: y, width: width, height: height))
                y += height + Float(random.next(3) * 15)
            }
        }
        for _ in 0..<12 {
            result.append(
                Rect(
                    x: random.coordinate(),
                    y: random.coordinate(),
                    width: Float(random.next(240)),
                    height: Float(random.next(120))
                )
            )
        }
        return result
    }

    /// Strokes that start on, cross and stop at rectangle edges, and a few diagonals.
    private func stroke(_ random: inout Random, near rects: [Rect]) -> (Point, Point) {
        func coordinate(_ edges: (Rect) -> [Float]) -> Float {
            guard random.next(3) != 0 else { return random.coordinate() }
            return edges(rects[random.next(rects.count)])[random.next(3)]
        }
        let x = coordinate { [$0.left, $0.right, $0.center.x] }
        let y = coordinate { [$0.top, $0.bottom, $0.center.y] }
        switch random.next(5) {
        case 0: return (Point(x: x, y: y), Point(x: coordinate { [$0.left, $0.right, $0.center.x] }, y: y))
        case 1: return (Point(x: x, y: y), Point(x: x, y: coordinate { [$0.top, $0.bottom, $0.center.y] }))
        case 2: return (Point(x: x, y: y), Point(x: x + DirectedGeometry.epsilon / 2, y: random.coordinate()))
        case 3: return (Point(x: x, y: y), Point(x: x, y: y))
        default: return (Point(x: x, y: y), Point(x: random.coordinate(), y: random.coordinate()))
        }
    }

    @Test(arguments: [1, 2, 3, 4] as [UInt64])
    func indexedClearanceMatchesTheLinearScan(seed: UInt64) {
        var random = Random(seed: seed)
        let bodies = rects(&random)
        let index = DirectedObstacleIndex(bodies)
        var blocked = 0
        for _ in 0..<3_000 {
            let (a, b) = stroke(&random, near: bodies)
            let skipped = random.next(4) == 0 ? nil : random.next(bodies.count)
            let alsoSkipped = random.next(2) == 0 ? skipped : random.next(bodies.count)
            let others = bodies.indices.filter { $0 != skipped && $0 != alsoSkipped }.map { bodies[$0] }
            let expected = DirectedGeometry.clear(a, b, bodies: others)
            if !expected { blocked += 1 }
            #expect(index.clear(a, b, skipping: skipped, alsoSkipped) == expected, "\(a) – \(b)")
        }
        // Both outcomes are exercised.
        #expect(blocked > 300 && blocked < 2_700)
    }

    @Test func emptyIndexIsAlwaysClearForAxisAlignedStrokes() {
        let index = DirectedObstacleIndex([])
        #expect(index.clear(Point(x: 0, y: 0), Point(x: 100, y: 0)))
        #expect(!index.clear(Point(x: 0, y: 0), Point(x: 100, y: 100)), "diagonals are never clear")
    }
}
