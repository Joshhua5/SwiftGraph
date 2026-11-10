import Foundation

/// Barnes–Hut force tree. Rebuild after moving the input points.
public final class ForceQuadTree {
    public var theta: Float

    private final class Cell {
        let bounds: Rect
        var points: [Int] = []
        var children: [Cell] = []
        var mass = 0
        var center = Point.zero

        init(_ bounds: Rect) { self.bounds = bounds }
    }

    /// The built tree, flattened breadth-first so each cell's four children are contiguous. Queries walk value
    /// arrays by index, avoiding the reference counting and exclusivity checks of walking `Cell` objects.
    private struct FlatCell {
        var bounds: Rect
        var center: Point
        var mass: Int

        /// Index of the first of four children, or -1 for a leaf.
        var firstChild: Int

        /// The leaf's bodies, as a range of `members`.
        var memberStart: Int
        var memberCount: Int
    }

    private var cells: [FlatCell] = []
    private var members: [Int] = []
    private var points: [Point] = []

    public init(theta: Float = 0.8) { self.theta = theta }

    @_disfavoredOverload
    public init(theta: Double) { self.theta = Float(theta) }

    public func build(_ points: [Point]) {
        self.points = points
        cells = []
        members = []
        guard let first = points.first else { return }
        // `points.first` was unwrapped just above, so every min/max below has a value.
        let minX = points.map(\.x).min()!
        let minY = points.map(\.y).min()!
        let size = max(1, max(points.map(\.x).max()! - minX, points.map(\.y).max()! - minY)) + 1e-6
        let root = Cell(Rect(x: minX, y: minY, width: size, height: size))
        root.center = first
        for i in points.indices { insert(i, into: root, depth: 0) }
        func flat(_ cell: Cell) -> FlatCell {
            defer { members.append(contentsOf: cell.points) }
            return FlatCell(
                bounds: cell.bounds,
                center: cell.center,
                mass: cell.mass,
                firstChild: -1,
                memberStart: members.count,
                memberCount: cell.points.count
            )
        }
        // Queue positions equal flat indices, so children appended together stay contiguous.
        var queue = [root]
        var head = 0
        cells.append(flat(root))
        while head < queue.count {
            let cell = queue[head]
            if !cell.children.isEmpty {
                cells[head].firstChild = cells.count
                for child in cell.children {
                    queue.append(child)
                    cells.append(flat(child))
                }
            }
            head += 1
        }
    }

    private func insert(_ i: Int, into cell: Cell, depth: Int) {
        cell.center = (cell.center * Float(cell.mass) + points[i]) / Float(cell.mass + 1)
        cell.mass += 1
        if cell.children.isEmpty && (cell.points.isEmpty || depth >= 40) {
            cell.points.append(i)
            return
        }
        if cell.children.isEmpty {
            let r = cell.bounds
            let half = r.width / 2
            cell.children = (0..<4)
                .map { k in
                    Cell(Rect(x: r.x + Float(k % 2) * half, y: r.y + Float(k / 2) * half, width: half, height: half))
                }
            let old = cell.points
            cell.points.removeAll()
            for index in old { insert(index, into: cell.children[quadrant(points[index], cell)], depth: depth + 1) }
        }
        insert(i, into: cell.children[quadrant(points[i], cell)], depth: depth + 1)
    }

    private func quadrant(_ point: Point, _ cell: Cell) -> Int {
        (point.x >= cell.bounds.center.x ? 1 : 0) + (point.y >= cell.bounds.center.y ? 2 : 0)
    }

    public func computeForce(nodeIndex: Int, position: Point, repulsionSquared: Float) -> Point {
        guard !cells.isEmpty else { return .zero }
        let cells = cells
        let members = members
        let points = points
        let theta = theta
        let angle = Double(nodeIndex) * 2.399963229728653
        let perturbation = Point(x: Float(cos(angle) * 0.1), y: Float(sin(angle) * 0.1))
        var force = Point.zero
        var stack: [Int] = []
        stack.reserveCapacity(64)
        stack.append(0)
        func contribution(_ other: Point, mass: Int) -> Point {
            var delta = position - other
            var squared = delta.lengthSquared
            if squared > 250_000 { return .zero }
            if squared < 0.01 {
                delta = perturbation
                squared = delta.lengthSquared
            }
            return delta * (repulsionSquared * Float(mass) / squared)
        }
        while let index = stack.popLast() {
            let cell = cells[index]
            guard cell.mass > 0 else { continue }
            if cell.firstChild < 0 {
                for k in cell.memberStart..<(cell.memberStart + cell.memberCount) where members[k] != nodeIndex {
                    force = force + contribution(points[members[k]], mass: 1)
                }
            } else {
                let distance = (position - cell.center).lengthSquared
                // Never approximate a cell containing the query: that would include self mass.
                let centerOffset = position - cell.bounds.center
                let half = cell.bounds.width / 2
                let nearX = max(0, abs(centerOffset.x) - half)
                let nearY = max(0, abs(centerOffset.y) - half)
                if nearX * nearX + nearY * nearY > 250_000 { continue }
                let farX = abs(centerOffset.x) + half
                let farY = abs(centerOffset.y) + half
                // Open cells crossing the cutoff, so in-range bodies are not lost to a distant centroid.
                if !cell.bounds.contains(position) && farX * farX + farY * farY <= 250_000
                    && cell.bounds.width * cell.bounds.width < theta * theta * distance
                {
                    force = force + contribution(cell.center, mass: cell.mass)
                } else {
                    // Pushed last-first so they pop in order, keeping the summation order (and result) unchanged.
                    for k in stride(from: 3, through: 0, by: -1) { stack.append(cell.firstChild + k) }
                }
            }
        }
        return force
    }
}
