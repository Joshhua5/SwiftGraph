import Foundation

public enum OrganicBackend: String, CaseIterable, Sendable { case cpuExact, cpuBarnesHut, metal }
public enum OrganicLayoutError: Error, CustomStringConvertible {
    case metalUnavailable
    case invalidConfiguration(String)
    case metalFailure(String)
    public var description: String {
        switch self {
        case .metalUnavailable: return "No Metal compute device is available. Select cpuExact or cpuBarnesHut."
        case .invalidConfiguration(let message): return "Invalid layout input: \(message)"
        case .metalFailure(let message): return "Metal layout failed: \(message)"
        }
    }
}

public struct OrganicLayoutMetrics: Sendable {
    public let backend: OrganicBackend
    public let nodeCount: Int
    public let iterations: Int
    /// Includes preparation, buffer allocation, submission, waiting and graph write-back; excludes solver initialization.
    public let wallTimeSeconds: Double
    /// Command-buffer GPU time only. Nil on CPU backends.
    public let gpuTimeSeconds: Double?
}

/// Experimental Metal acceleration of Waring's organic force model.
///
/// One instance and its mutable graph must be confined to a single caller. Construction compiles the
/// Metal kernel once. Execution is synchronous; run it off the UI actor. Cancellation is checked at
/// every CPU iteration and between bounded Metal batches. The graph is only updated after success.
public final class AcceleratedOrganicLayoutAlgorithm: LayoutAlgorithm {
    public let backend: OrganicBackend
    public var scope: OrganicScope = .all
    public var iterations = 100
    public var initialTemperature: Float = 100
    public var repulsionForce: Float = 2_000
    public var attractionForce: Float = 0.05
    public var barnesHutTheta: Float = 0.8
    public var metalBatchSize = 8
    public private(set) var lastMetrics: OrganicLayoutMetrics?
    private let metal: MetalForceSolver?

    public init(backend: OrganicBackend = .cpuBarnesHut) throws {
        self.backend = backend
        metal = backend == .metal ? try MetalForceSolver() : nil
    }
    public static var isMetalAvailable: Bool { MetalForceSolver.isAvailable }
    public var deviceName: String? { metal?.deviceName }

    public func applyLayout(_ graph: LayoutGraph) throws {
        lastMetrics = nil
        try Task.checkCancellation()
        guard iterations >= 0, initialTemperature.isFinite, initialTemperature >= 0,
              repulsionForce.isFinite, repulsionForce >= 0, attractionForce.isFinite, attractionForce >= 0,
              barnesHutTheta.isFinite, barnesHutTheta > 0, metalBatchSize > 0,
              repulsionForce <= sqrt(Float.greatestFiniteMagnitude) else {
            throw OrganicLayoutError.invalidConfiguration("Forces and temperature must be finite and nonnegative; iterations nonnegative; theta and batch size positive.")
        }
        let start = ContinuousClock.now
        var state = try ForceState(graph, scope: scope, scatter: iterations > 0)
        var gpuTime: Double?
        if !state.positions.isEmpty && iterations > 0 {
            let parameters = ForceParameters(repulsionSquared: repulsionForce * repulsionForce, attraction: attractionForce)
            if let metal {
                let result = try metal.solve(state, iterations: iterations, temperature: initialTemperature,
                                             parameters: parameters, batchSize: metalBatchSize)
                state.positions = result.positions; gpuTime = result.gpuSeconds
            } else {
                for step in 0..<iterations {
                    try Task.checkCancellation()
                    let temperature = initialTemperature * (1 - Float(step) / Float(iterations))
                    state.positions = try cpuStep(state, parameters: parameters, temperature: temperature,
                                                  theta: backend == .cpuBarnesHut ? barnesHutTheta : nil)
                }
            }
            guard state.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw OrganicLayoutError.invalidConfiguration("Force calculation overflowed Float coordinates.")
            }
            try Task.checkCancellation()
            let pinned = state.fixed.contains(1)
            let minX = pinned ? 0 : (state.positions.map(\.x).min() ?? 0)
            let minY = pinned ? 0 : (state.positions.map(\.y).min() ?? 0)
            // Never rewrite fixed nodes: preserve exact bits.
            for i in graph.nodes.indices where state.fixed[i] == 0 {
                graph.nodes[i].center = Point(x: state.positions[i].x - minX, y: state.positions[i].y - minY)
            }
        }
        let elapsed = start.duration(to: .now)
        lastMetrics = OrganicLayoutMetrics(backend: backend, nodeCount: graph.nodes.count, iterations: iterations,
                                           wallTimeSeconds: elapsed.seconds, gpuTimeSeconds: gpuTime)
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
struct ForceParameters: Sendable { var repulsionSquared: Float; var attraction: Float }
struct ForceState: Sendable {
    var positions: [SIMD2<Float>]
    var fixed: [UInt32]
    var offsets: [UInt32]
    var neighbors: [UInt32]
    init(positions: [SIMD2<Float>], fixed: [UInt32], offsets: [UInt32], neighbors: [UInt32]) {
        self.positions = positions; self.fixed = fixed; self.offsets = offsets; self.neighbors = neighbors
    }
    init(_ graph: LayoutGraph, scope: OrganicScope, scatter: Bool) throws {
        guard graph.nodes.count < Int(UInt32.max), Set(graph.nodes).count == graph.nodes.count else {
            throw OrganicLayoutError.invalidConfiguration("Node references must be unique and fit in 32-bit indices.")
        }
        guard graph.nodes.allSatisfy({ n in
            [n.x, n.y, n.width, n.height, n.center.x, n.center.y].allSatisfy { $0.isFinite && abs($0) < 1e15 }
                && n.width >= 0 && n.height >= 0
        }) else { throw OrganicLayoutError.invalidConfiguration("Finite coordinates within ±1e15 and nonnegative dimensions are required.") }
        positions = graph.nodes.map { SIMD2($0.center.x, $0.center.y) }
        fixed = graph.nodes.map { n in
            (n.metadata[GraphMetadataKeys.fixed] as? Bool == true ||
             (scope == .subset && n.metadata[GraphMetadataKeys.layoutSubset] as? Bool != true)) ? 1 : 0
        }
        // Stable seed, shared by all backends. Deliberately not .NET Random's implementation.
        if scatter && graph.nodes.allSatisfy({ $0.x == 0 && $0.y == 0 }) {
            var random = SplitMix64(seed: 42)
            for i in positions.indices where fixed[i] == 0 {
                positions[i] = SIMD2(random.unitFloat() * 1_000 + graph.nodes[i].width / 2,
                                     random.unitFloat() * 1_000 + graph.nodes[i].height / 2)
            }
        }
        let adjacency = Adjacency(graph)
        offsets = [0]; neighbors = []
        for adjacent in adjacency.neighbors {
            guard neighbors.count + adjacent.count < Int(UInt32.max) else {
                throw OrganicLayoutError.invalidConfiguration("Adjacency must fit in 32-bit indices.")
            }
            neighbors.append(contentsOf: adjacent.map(UInt32.init)); offsets.append(UInt32(neighbors.count))
        }
    }
}
struct SplitMix64 {
    var seed: UInt64
    mutating func unitFloat() -> Float {
        seed &+= 0x9E3779B97F4A7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }
}
func repulsiveForce(_ point: SIMD2<Float>, _ other: SIMD2<Float>, index: Int, otherIndex: Int,
                    strength: Float) -> SIMD2<Float> {
    var delta = point - other
    var squared = delta.x * delta.x + delta.y * delta.y
    if squared < 0.01 {
        let sign: Float = index > otherIndex ? 1 : -1
        delta = SIMD2(repeating: 0.1 * sign); squared = 0.02
    }
    if squared > 250_000 { return .zero }
    return delta * (strength / squared)
}
func cpuStep(_ state: ForceState, parameters: ForceParameters, temperature: Float, theta: Float?) throws -> [SIMD2<Float>] {
    var result = state.positions
    let tree = theta.map { ForceTree(state.positions, theta: $0) }
    for i in state.positions.indices where state.fixed[i] == 0 {
        if i % 64 == 0 { try Task.checkCancellation() }
        let point = state.positions[i]
        var force = SIMD2<Float>.zero
        if let tree { force = tree.force(on: i, strength: parameters.repulsionSquared) }
        else {
            for j in state.positions.indices where i != j {
                force += repulsiveForce(point, state.positions[j], index: i, otherIndex: j, strength: parameters.repulsionSquared)
            }
        }
        for k in Int(state.offsets[i])..<Int(state.offsets[i + 1]) {
            force += (state.positions[Int(state.neighbors[k])] - point) * parameters.attraction
        }
        let distance = sqrt(force.x * force.x + force.y * force.y)
        if distance > 0.1 { result[i] += force * (min(distance, temperature) / distance) }
    }
    return result
}

/// Barnes–Hut baseline. Cells intersecting the 500-unit cutoff are opened rather than approximated.
struct ForceTree {
    struct Cell {
        var center: SIMD2<Float>
        var size: Float
        var massCenter: SIMD2<Float>
        var bodies: [Int]
        var children: [Int]
        var mass: Int
    }
    var cells: [Cell] = []
    let positions: [SIMD2<Float>]
    let theta: Float
    init(_ positions: [SIMD2<Float>], theta: Float) {
        self.positions = positions; self.theta = theta
        guard !positions.isEmpty else { return }
        let minX = positions.map(\.x).min()!, maxX = positions.map(\.x).max()!
        let minY = positions.map(\.y).min()!, maxY = positions.map(\.y).max()!
        _ = build(Array(positions.indices), center: SIMD2((minX + maxX) / 2, (minY + maxY) / 2), size: max(1, max(maxX - minX, maxY - minY) * 1.001), depth: 0)
    }
    mutating func build(_ indices: [Int], center: SIMD2<Float>, size: Float, depth: Int) -> Int {
        let index = cells.count
        let mean = indices.reduce(SIMD2<Float>.zero) { $0 + positions[$1] } / Float(indices.count)
        cells.append(Cell(center: center, size: size, massCenter: mean, bodies: [], children: [], mass: indices.count))
        if indices.count <= 1 || depth >= 32 || size < 0.001 {
            cells[index].bodies = indices; return index
        }
        var groups = Array(repeating: [Int](), count: 4)
        for i in indices { groups[(positions[i].x >= center.x ? 1 : 0) + (positions[i].y >= center.y ? 2 : 0)].append(i) }
        var children: [Int] = []
        for q in 0..<4 where !groups[q].isEmpty {
            let offset = SIMD2<Float>(q & 1 == 0 ? -1 : 1, q & 2 == 0 ? -1 : 1) * (size / 4)
            children.append(build(groups[q], center: center + offset, size: size / 2, depth: depth + 1))
        }
        cells[index].children = children
        return index
    }
    func force(on i: Int, strength: Float) -> SIMD2<Float> {
        guard !cells.isEmpty else { return .zero }
        let point = positions[i]
        var stack = [0], force = SIMD2<Float>.zero
        while let index = stack.popLast() {
            let cell = cells[index]
            if cell.children.isEmpty {
                for j in cell.bodies where i != j { force += repulsiveForce(point, positions[j], index: i, otherIndex: j, strength: strength) }
                continue
            }
            let offset = point - cell.center, half = cell.size / 2
            let nearX = max(0, abs(offset.x) - half), nearY = max(0, abs(offset.y) - half)
            if nearX * nearX + nearY * nearY > 250_000 { continue }
            let farX = abs(offset.x) + half, farY = abs(offset.y) + half
            let delta = point - cell.massCenter, squared = delta.x * delta.x + delta.y * delta.y
            let containsSelf = abs(offset.x) <= half && abs(offset.y) <= half
            if !containsSelf && farX * farX + farY * farY <= 250_000 && cell.size * cell.size < theta * theta * squared {
                force += delta * (strength * Float(cell.mass) / max(squared, 0.02))
            } else { stack.append(contentsOf: cell.children.reversed()) }
        }
        return force
    }
}
