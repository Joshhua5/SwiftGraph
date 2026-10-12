import Foundation

struct SeededRandom {
    var state: UInt64 = 42
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / 9007199254740992
    }
}

/// Barnes–Hut force tree. Rebuild after moving the input points.
public final class ForceQuadTree {
    public var theta: Double
    private final class Cell {
        let bounds: Rect
        var points: [Int] = []
        var children: [Cell] = []
        var mass = 0
        var center = Point.zero
        init(_ bounds: Rect) { self.bounds = bounds }
    }
    private var root: Cell?
    private var points: [Point] = []
    public init(theta: Double = 0.8) { self.theta = theta }
    public func build(_ points: [Point]) {
        self.points = points
        guard let first = points.first else { root = nil; return }
        let minX = points.map(\.x).min()!, minY = points.map(\.y).min()!
        let size = max(1, max(points.map(\.x).max()! - minX, points.map(\.y).max()! - minY)) + 1e-6
        let cell = Cell(Rect(x: minX, y: minY, width: size, height: size))
        cell.center = first
        root = cell
        for i in points.indices { insert(i, into: cell, depth: 0) }
    }
    private func insert(_ i: Int, into cell: Cell, depth: Int) {
        cell.center = (cell.center * Double(cell.mass) + points[i]) / Double(cell.mass + 1); cell.mass += 1
        if cell.children.isEmpty && (cell.points.isEmpty || depth >= 40) { cell.points.append(i); return }
        if cell.children.isEmpty {
            let r = cell.bounds, half = r.width / 2
            cell.children = (0..<4).map { k in Cell(Rect(x: r.x + Double(k % 2) * half, y: r.y + Double(k / 2) * half, width: half, height: half)) }
            let old = cell.points; cell.points.removeAll()
            for index in old { insert(index, into: cell.children[quadrant(points[index], cell)], depth: depth + 1) }
        }
        insert(i, into: cell.children[quadrant(points[i], cell)], depth: depth + 1)
    }
    private func quadrant(_ point: Point, _ cell: Cell) -> Int {
        (point.x >= cell.bounds.center.x ? 1 : 0) + (point.y >= cell.bounds.center.y ? 2 : 0)
    }
    public func computeForce(nodeIndex: Int, position: Point, repulsionSquared: Double) -> Point {
        guard let root else { return .zero }
        var force = Point.zero, stack = [root]
        func contribution(_ other: Point, mass: Int) -> Point {
            var delta = position - other
            if delta.lengthSquared > 250_000 { return .zero }
            if delta.lengthSquared < 0.01 {
                let angle = Double(nodeIndex) * 2.399963229728653
                delta = Point(x: cos(angle) * 0.1, y: sin(angle) * 0.1)
            }
            return delta * (repulsionSquared * Double(mass) / delta.lengthSquared)
        }
        while let cell = stack.popLast() {
            guard cell.mass > 0 else { continue }
            if cell.children.isEmpty {
                for i in cell.points where i != nodeIndex { force = force + contribution(points[i], mass: 1) }
            } else {
                let distance = (position - cell.center).lengthSquared
                // Never approximate a cell containing the query: that would include self mass.
                let centerOffset = position - cell.bounds.center, half = cell.bounds.width / 2
                let nearX = max(0, abs(centerOffset.x) - half), nearY = max(0, abs(centerOffset.y) - half)
                if nearX * nearX + nearY * nearY > 250_000 { continue }
                let farX = abs(centerOffset.x) + half, farY = abs(centerOffset.y) + half
                // Open cells crossing the cutoff, so in-range bodies are not lost to a distant centroid.
                if !cell.bounds.contains(position) && farX * farX + farY * farY <= 250_000 && cell.bounds.width * cell.bounds.width < theta * theta * distance {
                    force = force + contribution(cell.center, mass: cell.mass)
                } else { stack.append(contentsOf: cell.children.reversed()) }
            }
        }
        return force
    }
}

public enum OrganicScope: Sendable { case all, subset }
public final class OrganicLayoutAlgorithm: LayoutAlgorithm {
    public typealias OrganicScope = SwiftGraph.OrganicScope
    public let quality: OrganicLayoutQuality
    public var initialization: OrganicInitialization = .automatic
    public var nodeSeparation: Double = 20
    public var scope: OrganicScope = .all
    public var iterations: Double
    public var initialTemperature: Double = 100
    public var repulsionForce: Double
    public var attractionForce: Double = 0.05
    public private(set) var lastDiagnostics: OrganicLayoutDiagnostics?
    var preparedPositions = false
    public init(quality: OrganicLayoutQuality = .quality) {
        self.quality = quality
        iterations = quality == .quality ? 600 : 100
        repulsionForce = quality == .quality ? 100 : 2000
    }
    public func applyLayout(_ graph: LayoutGraph) throws {
        lastDiagnostics = nil
        try Task.checkCancellation()
        if quality == .quality {
            var configuration = OrganicLayoutConfiguration()
            guard iterations.isFinite, iterations >= 0, iterations < Double(Int.max / 16) else {
                throw LayoutExecutionError.invalidInput("Iterations must be finite and nonnegative.")
            }
            configuration.iterations = Int(ceil(iterations)); configuration.scope = scope
            configuration.initialization = initialization; configuration.nodeSeparation = nodeSeparation
            configuration.initialTemperature = initialTemperature
            configuration.repulsionForce = repulsionForce; configuration.attractionForce = attractionForce
            try configuration.validate()
            let checkpoint = try GraphCheckpoint(graph)
            var search = try OrganicQualitySearch(checkpoint.snapshot, configuration)
            if configuration.iterations > 0 && search.fixed.contains(false) {
                for start in search.starts() {
                    for strength in [0.5, 1.0, 2.0] {
                        let (input, candidate) = search.candidate(start, strength: strength)
                        try search.consider(input.cpuOrganic(candidate))
                    }
                }
            }
            try Task.checkCancellation()
            for i in graph.nodes.indices where !search.fixed[i] && configuration.iterations > 0 { graph.nodes[i].center = search.best[i] }
            lastDiagnostics = search.diagnostics
            return
        }
        let a = Adjacency(graph), nodes = a.nodes
        guard !nodes.isEmpty, iterations > 0, iterations.isFinite else { return }
        let fixed = nodes.map { ($0.metadata[GraphMetadataKeys.fixed] as? Bool == true) || (scope == .subset && $0.metadata[GraphMetadataKeys.layoutSubset] as? Bool != true) }
        var positions = nodes.map(\.center), random = SeededRandom()
        if !preparedPositions && nodes.allSatisfy({ $0.x == 0 && $0.y == 0 }) {
            for i in nodes.indices where !fixed[i] { positions[i] = Point(x: random.next() * 1000 + nodes[i].width / 2, y: random.next() * 1000 + nodes[i].height / 2) }
        }
        let tree = ForceQuadTree(), repulsionSquared = repulsionForce * repulsionForce
        for iteration in 0..<Int(ceil(iterations)) {
            try Task.checkCancellation()
            var displacement = Array(repeating: Point.zero, count: nodes.count)
            if nodes.count >= 64 {
                tree.build(positions)
                for i in nodes.indices { displacement[i] = tree.computeForce(nodeIndex: i, position: positions[i], repulsionSquared: repulsionSquared) }
            } else {
                for i in nodes.indices {
                    for j in nodes.indices where i != j {
                        var delta = positions[i] - positions[j]
                        if delta.lengthSquared < 0.01 { let sign = i > j ? 0.1 : -0.1; delta = Point(x: sign, y: sign) }
                        if delta.lengthSquared <= 250_000 { displacement[i] = displacement[i] + delta * (repulsionSquared / delta.lengthSquared) }
                    }
                }
            }
            for i in nodes.indices {
                for j in a.outgoing[i] {
                    let force = (positions[i] - positions[j]) * attractionForce
                    displacement[i] = displacement[i] - force; displacement[j] = displacement[j] + force
                }
            }
            let temperature = max(0, initialTemperature * (1 - Double(iteration) / iterations))
            for i in nodes.indices where !fixed[i] {
                let length = displacement[i].length
                if length > 0.1 { positions[i] = positions[i] + displacement[i] * (min(length, temperature) / length) }
            }
        }
        let offset = fixed.contains(true) ? Point.zero : Point(x: positions.map(\.x).min()!, y: positions.map(\.y).min()!)
        try Task.checkCancellation()
        for i in nodes.indices where !fixed[i] { nodes[i].center = positions[i] - offset }
    }
}

public final class BarycenterLayoutAlgorithm: LayoutAlgorithm {
    public var iterations = 3
    public var minSpacing: Double = 10
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph), bounds = graph.bounds
        var fixed = a.nodes.map { $0.metadata[GraphMetadataKeys.fixed] as? Bool == true }
        if !fixed.contains(true) {
            fixed = a.nodes.map { $0.x <= bounds.left + 1 || $0.bounds.right >= bounds.right - 1 || $0.y <= bounds.top + 1 || $0.bounds.bottom >= bounds.bottom - 1 }
        }
        var positions = a.nodes.map(\.center)
        for _ in 0..<max(0, iterations) {
            try Task.checkCancellation()
            var next = positions
            for i in a.nodes.indices where !fixed[i] && !a.neighbors[i].isEmpty {
                next[i] = a.neighbors[i].reduce(Point.zero) { $0 + positions[$1] } / Double(a.neighbors[i].count)
            }
            positions = next
        }
        for i in a.nodes.indices where !fixed[i] { a.nodes[i].center = positions[i] }
        // Averaging pulls nodes that share neighbors onto one point; spread them without moving anchors.
        _ = try separateOverlaps(a.nodes, spacing: minSpacing, movable: fixed.map { !$0 })
        straightEdges(graph)
    }
}

public final class PageRankAlgorithm: LayoutAlgorithm {
    public var dampingFactor: Double = 0.85
    public var iterations = 20
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph), n = a.nodes.count
        guard n > 0 else { return }
        var incoming = a.incoming, degree = a.outgoing.map(\.count)
        // Self-links count for PageRank even though layout adjacency omits them.
        for e in graph.edges where e.source === e.target {
            if let i = a.index[e.source] { incoming[i].append(i); degree[i] += 1 }
        }
        var ranks = Array(repeating: 1 / Double(n), count: n)
        for _ in 0..<max(0, iterations) {
            try Task.checkCancellation()
            let dangling = (0..<n).filter { degree[$0] == 0 }.reduce(0.0) { $0 + ranks[$1] }
            ranks = (0..<n).map { i in
                let links = incoming[i].reduce(0.0) { $0 + ranks[$1] / Double(degree[$1]) }
                return (1 - dampingFactor) / Double(n) + dampingFactor * (links + dangling / Double(n))
            }
        }
        for i in 0..<n { a.nodes[i].metadata[GraphMetadataKeys.pageRank] = ranks[i] }
    }
}

public final class LabelPropagationClusteringAlgorithm: LayoutAlgorithm {
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        var labels = Array(a.nodes.indices), order = labels, random = SeededRandom()
        for _ in 0..<20 {
            try Task.checkCancellation()
            if order.count > 1 {
                for i in stride(from: order.count - 1, through: 1, by: -1) { order.swapAt(i, Int(random.next() * Double(i + 1))) }
            }
            var changed = false
            for i in order {
                var counts: [Int: Int] = [:], labelOrder: [Int] = []
                for j in a.neighbors[i] {
                    if counts[labels[j]] == nil { labelOrder.append(labels[j]) }
                    counts[labels[j], default: 0] += 1
                }
                var best = labels[i], bestCount = counts[best, default: 0]
                for label in labelOrder where counts[label]! > bestCount { best = label; bestCount = counts[label]! }
                if labels[i] != best { changed = true; labels[i] = best }
            }
            if !changed { break }
        }
        for i in a.nodes.indices { a.nodes[i].metadata[GraphMetadataKeys.cluster] = labels[i] }
    }
}
@available(*, deprecated, renamed: "LabelPropagationClusteringAlgorithm")
public typealias LouvainClusteringAlgorithm = LabelPropagationClusteringAlgorithm
