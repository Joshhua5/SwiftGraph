import Foundation

public enum OrganicLayoutQuality: Sendable { case quality, legacy }
public enum OrganicInitialization: Sendable { case automatic, current }

/// Placement measurements, before any edge router is run. Lower values are preferred.
public struct OrganicQualityMeasurements: Sendable, Equatable {
    public var clearanceViolations: Int
    public var edgeNodeIntersections: Int
    public var crossings: Int
    public var edgeLength: Double
    public var drawingArea: Double

    func precedes(_ other: Self) -> Bool {
        let lhs = [Double(clearanceViolations), Double(edgeNodeIntersections), Double(crossings), edgeLength, drawingArea]
        let rhs = [Double(other.clearanceViolations), Double(other.edgeNodeIntersections), Double(other.crossings), other.edgeLength, other.drawingArea]
        for (a, b) in zip(lhs, rhs) where a != b { return a < b }
        return false
    }
}

public struct OrganicLayoutDiagnostics: Sendable {
    /// Includes the unchanged input candidate, at index zero.
    public var candidateCount: Int
    public var selectedCandidate: Int
    public var solverIterations: Int
    /// Stable node indices. These constraints cannot be resolved without moving a fixed node.
    public var fixedConflicts: [[Int]]
    public var initial: OrganicQualityMeasurements
    public var final: OrganicQualityMeasurements
}

/// Backend-independent candidate preparation, rectangle separation, packing and scoring.
struct OrganicQualitySearch {
    let snapshot: GeometrySnapshot
    let configuration: OrganicLayoutConfiguration
    let fixed: [Bool]
    let components: [[Int]]
    var best: [Point]
    var diagnostics: OrganicLayoutDiagnostics

    init(_ snapshot: GeometrySnapshot, _ configuration: OrganicLayoutConfiguration) throws {
        self.snapshot = snapshot; self.configuration = configuration
        fixed = snapshot.nodes.map { $0.fixed || (configuration.scope == .subset && !$0.selected) }
        components = Self.components(snapshot)
        best = snapshot.nodes.map { $0.bounds.center }
        let initial = try Self.measure(best, snapshot, separation: configuration.nodeSeparation)
        let bounds = snapshot.nodes.map(\.bounds)
        var conflicts: [[Int]] = []
        for i in bounds.indices where fixed[i] {
            for j in bounds.indices where j > i && fixed[j] {
                if Self.conflict(bounds[i], bounds[j], configuration.nodeSeparation) { conflicts.append([i, j]) }
            }
        }
        diagnostics = OrganicLayoutDiagnostics(candidateCount: 1, selectedCandidate: 0, solverIterations: 0,
                                                fixedConflicts: conflicts, initial: initial, final: initial)
    }

    func starts() -> [[Point]] {
        let original = snapshot.nodes.map { $0.bounds.center }
        guard configuration.initialization == .automatic else { return [original] }
        let anchors = original.indices.filter { fixed[$0] }
        let center = anchors.isEmpty ? Point.zero : anchors.reduce(Point.zero) { $0 + original[$1] } / Double(anchors.count)
        let area = snapshot.nodes.reduce(0.0) { $0 + ($1.bounds.width + configuration.nodeSeparation) * ($1.bounds.height + configuration.nodeSeparation) }
        let side = max(100, sqrt(area) * 2)
        return [original] + (42...44).map { seed in
            var random = SeededRandom(state: UInt64(seed)), positions = original
            for i in positions.indices where !fixed[i] {
                positions[i] = center + Point(x: (random.next() - 0.5) * side, y: (random.next() - 0.5) * side)
            }
            return positions
        }
    }

    func candidate(_ positions: [Point], strength: Double) -> (GeometrySnapshot, OrganicLayoutConfiguration) {
        var input = snapshot
        for i in input.nodes.indices {
            let r = input.nodes[i].bounds
            input.nodes[i].bounds = Rect(x: positions[i].x - r.width / 2, y: positions[i].y - r.height / 2, width: r.width, height: r.height)
        }
        var c = OrganicLayoutConfiguration(quality: .legacy)
        c.scope = configuration.scope; c.iterations = configuration.iterations
        c.initialTemperature = configuration.initialTemperature
        c.repulsionForce = configuration.repulsionForce * strength; c.attractionForce = configuration.attractionForce
        c.preparedPositions = true
        return (input, c)
    }

    mutating func consider(_ raw: [Point]) throws {
        try Task.checkCancellation()
        guard raw.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw LayoutExecutionError.invalidInput("Non-finite organic candidate.")
        }
        var positions = raw
        // Preserve Double coordinates even when a GPU candidate returned rounded pins.
        for i in positions.indices where fixed[i] { positions[i] = snapshot.nodes[i].bounds.center }
        compact(&positions)
        try separate(&positions)
        try pack(&positions)
        if !fixed.contains(true), let first = rectangles(positions).first {
            let bounds = rectangles(positions).dropFirst().reduce(first) { $0.union($1) }
            positions = positions.map { $0 - Point(x: bounds.x, y: bounds.y) }
        }
        let score = try Self.measure(positions, snapshot, separation: configuration.nodeSeparation)
        let index = diagnostics.candidateCount
        diagnostics.candidateCount += 1; diagnostics.solverIterations += configuration.iterations
        if score.precedes(diagnostics.final) {
            best = positions; diagnostics.final = score; diagnostics.selectedCandidate = index
        }
    }

    func rectangles(_ positions: [Point]) -> [Rect] {
        zip(positions, snapshot.nodes).map { p, node in
            Rect(x: p.x - node.bounds.width / 2, y: p.y - node.bounds.height / 2, width: node.bounds.width, height: node.bounds.height)
        }
    }

    static func conflict(_ a: Rect, _ b: Rect, _ gap: Double) -> Bool {
        // A tiny tolerance prevents floating-point boundary contact from becoming a conflict.
        a.inflated(by: max(0, gap - 1e-7)).intersects(b)
    }

    func separate(_ positions: inout [Point]) throws {
        let gap = configuration.nodeSeparation
        for _ in 0..<32 {
            try Task.checkCancellation()
            var moved = false, bounds = rectangles(positions)
            for i in positions.indices {
                for j in positions.indices where j > i && !(fixed[i] && fixed[j]) {
                    guard Self.conflict(bounds[i], bounds[j], gap) else { continue }
                    let dx = (bounds[i].width + bounds[j].width) / 2 + gap - abs(positions[i].x - positions[j].x)
                    let dy = (bounds[i].height + bounds[j].height) / 2 + gap - abs(positions[i].y - positions[j].y)
                    let shift = dx <= dy ? Point(x: (positions[i].x <= positions[j].x ? -1 : 1) * (dx + 1e-6)) : Point(y: (positions[i].y <= positions[j].y ? -1 : 1) * (dy + 1e-6))
                    let left = fixed[i] ? 0.0 : (fixed[j] ? 1.0 : 0.5), right = fixed[j] ? 0.0 : (fixed[i] ? 1.0 : 0.5)
                    positions[i] = positions[i] + shift * left; bounds[i] = bounds[i].translated(by: shift * left)
                    positions[j] = positions[j] - shift * right; bounds[j] = bounds[j].translated(by: shift * -right)
                    moved = true
                }
            }
            if !moved { return }
        }
        // A finite placement fallback: fixed nodes first, then each movable node in stable order.
        var occupied = rectangles(positions).enumerated().filter { fixed[$0.offset] }.map(\.element)
        for i in positions.indices where !fixed[i] {
            try Task.checkCancellation()
            let r = rectangles([positions[i]], nodes: [snapshot.nodes[i]])[0]
            let offset = try Self.nearestPlacement(r, obstacles: occupied, gap: gap)
            positions[i] = positions[i] + offset; occupied.append(r.translated(by: offset))
        }
    }

    private func rectangles(_ positions: [Point], nodes: [GeometrySnapshot.Node]) -> [Rect] {
        zip(positions, nodes).map { p, n in Rect(x: p.x - n.bounds.width / 2, y: p.y - n.bounds.height / 2, width: n.bounds.width, height: n.bounds.height) }
    }

    static func nearestPlacement(_ rect: Rect, obstacles: [Rect], gap: Double) throws -> Point {
        guard obstacles.contains(where: { conflict(rect, $0, gap) }) else { return .zero }
        let padded = obstacles.map { $0.inflated(by: gap + 1e-6) }
        let xs = Set([0.0] + padded.flatMap { [$0.left - rect.right, $0.right - rect.left] }).sorted()
        let ys = Set([0.0] + padded.flatMap { [$0.top - rect.bottom, $0.bottom - rect.top] }).sorted()
        var best: Point?
        for x in xs {
            try Task.checkCancellation()
            for y in ys {
                let p = Point(x: x, y: y)
                if let best, p.lengthSquared >= best.lengthSquared { continue }
                if !padded.contains(where: { $0.intersects(rect.translated(by: p)) }) { best = p }
            }
        }
        guard let best else { throw LayoutExecutionError.invalidInput("Organic placement exceeded finite coordinates.") }
        return best
    }

    /// Force magnitudes determine the arrangement, not the final world-coordinate scale.
    /// Normalize unanchored components to their measured node sizes before rectangle separation.
    func compact(_ positions: inout [Point]) {
        for component in components where component.count > 1 && !component.contains(where: { fixed[$0] }) {
            let members = Set(component)
            let edges = snapshot.edges.filter { $0.source != $0.target && members.contains($0.source) && members.contains($0.target) }
            guard !edges.isEmpty else { continue }
            let lengths = edges.map { (positions[$0.source] - positions[$0.target]).length }.sorted()
            let targets = edges.map { e in
                let a = snapshot.nodes[e.source].bounds, b = snapshot.nodes[e.target].bounds
                return hypot(a.width, a.height) / 2 + hypot(b.width, b.height) / 2 + configuration.nodeSeparation
            }.sorted()
            let median = lengths[lengths.count / 2]
            guard median > 1e-9 else { continue }
            let scale = min(1, 2.5 * targets[targets.count / 2] / median)
            let center = component.reduce(Point.zero) { $0 + positions[$1] } / Double(component.count)
            for i in component { positions[i] = center + (positions[i] - center) * scale }
        }
    }

    func pack(_ positions: inout [Point]) throws {
        guard components.count > 1 else { return }
        let rects = rectangles(positions)
        let bounds = components.map { c in c.dropFirst().reduce(rects[c[0]]) { $0.union(rects[$1]) } }
        let anchored = components.indices.filter { c in components[c].contains { fixed[$0] } }
        let free = components.indices.filter { !anchored.contains($0) }.sorted {
            bounds[$0].height == bounds[$1].height ? $0 < $1 : bounds[$0].height > bounds[$1].height
        }
        var occupied = anchored.map { bounds[$0] }
        let gap = configuration.nodeSeparation
        let rowWidth = max(200, sqrt(bounds.reduce(0) { $0 + ($1.width + gap) * ($1.height + gap) }))
        var x = 0.0, y = 0.0, rowHeight = 0.0
        for c in free {
            try Task.checkCancellation()
            let r = bounds[c], delta: Point
            if anchored.isEmpty {
                if x > 0 && x + r.width > rowWidth { x = 0; y += rowHeight + gap; rowHeight = 0 }
                delta = Point(x: x - r.x, y: y - r.y)
                x += r.width + gap; rowHeight = max(rowHeight, r.height)
            } else { delta = try Self.nearestPlacement(r, obstacles: occupied, gap: gap) }
            for i in components[c] { positions[i] = positions[i] + delta }
            occupied.append(r.translated(by: delta))
        }
    }

    static func components(_ snapshot: GeometrySnapshot) -> [[Int]] {
        var adjacent = Array(repeating: [Int](), count: snapshot.nodes.count)
        for e in snapshot.edges { adjacent[e.source].append(e.target); adjacent[e.target].append(e.source) }
        var seen = Set<Int>(), result: [[Int]] = []
        for i in snapshot.nodes.indices where seen.insert(i).inserted {
            var queue = [i], cursor = 0
            while cursor < queue.count {
                let n = queue[cursor]; cursor += 1
                for next in adjacent[n] where seen.insert(next).inserted { queue.append(next) }
            }
            result.append(queue.sorted())
        }
        return result
    }

    static func measure(_ positions: [Point], _ snapshot: GeometrySnapshot, separation: Double) throws -> OrganicQualityMeasurements {
        let rects = zip(positions, snapshot.nodes).map { p, n in Rect(x: p.x - n.bounds.width / 2, y: p.y - n.bounds.height / 2, width: n.bounds.width, height: n.bounds.height) }
        var overlaps = 0, hits = 0, crossings = 0, length = 0.0
        for i in rects.indices {
            if i % 32 == 0 { try Task.checkCancellation() }
            for j in rects.indices where j > i { if conflict(rects[i], rects[j], separation) { overlaps += 1 } }
        }
        let edges = snapshot.edges.filter { $0.source != $0.target }
        let edgeBounds = edges.map { e -> (minX: Double, maxX: Double, minY: Double, maxY: Double) in
            let a = positions[e.source], b = positions[e.target]
            return (min(a.x, b.x), max(a.x, b.x), min(a.y, b.y), max(a.y, b.y))
        }
        for (index, e) in edges.enumerated() {
            if index % 32 == 0 { try Task.checkCancellation() }
            let a = positions[e.source], b = positions[e.target], eb = edgeBounds[index]
            length += (b - a).length
            for i in rects.indices where i != e.source && i != e.target {
                let r = rects[i]
                guard eb.maxX >= r.left && eb.minX <= r.right && eb.maxY >= r.top && eb.minY <= r.bottom else { continue }
                if r.intersectsLine(a, b) { hits += 1 }
            }
            for otherIndex in (index + 1)..<edges.count {
                let fb = edgeBounds[otherIndex]
                guard eb.maxX >= fb.minX && eb.minX <= fb.maxX && eb.maxY >= fb.minY && eb.minY <= fb.maxY else { continue }
                let f = edges[otherIndex]
                guard e.source != f.source && e.source != f.target && e.target != f.source && e.target != f.target else { continue }
                let c = positions[f.source], d = positions[f.target], u = b - a, v = d - c
                let denominator = u.x * v.y - u.y * v.x
                guard abs(denominator) > 1e-9 else { continue }
                let w = c - a, t = (w.x * v.y - w.y * v.x) / denominator, s = (w.x * u.y - w.y * u.x) / denominator
                if t > 1e-9 && t < 1 - 1e-9 && s > 1e-9 && s < 1 - 1e-9 { crossings += 1 }
            }
        }
        let bounds = rects.first.map { first in rects.dropFirst().reduce(first) { $0.union($1) } } ?? Rect()
        guard length.isFinite, (bounds.width * bounds.height).isFinite else { throw LayoutExecutionError.invalidInput("Organic quality measurements overflowed.") }
        return OrganicQualityMeasurements(clearanceViolations: overlaps, edgeNodeIntersections: hits, crossings: crossings, edgeLength: length, drawingArea: bounds.width * bounds.height)
    }
}
