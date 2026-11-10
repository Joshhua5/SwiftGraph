import Foundation

struct ForceParameters: Sendable {
    var repulsionSquared: Float
    var attraction: Float
}

struct ForceState: Sendable {
    var positions: [SIMD2<Float>]
    var fixed: [UInt32]
    var offsets: [UInt32]
    var neighbors: [UInt32]

    init(positions: [SIMD2<Float>], fixed: [UInt32], offsets: [UInt32], neighbors: [UInt32]) {
        self.positions = positions
        self.fixed = fixed
        self.offsets = offsets
        self.neighbors = neighbors
    }

    init(_ graph: LayoutGraph, scope: OrganicScope, scatter: Bool) throws {
        guard graph.nodes.count < Int(UInt32.max), Set(graph.nodes).count == graph.nodes.count else {
            throw OrganicLayoutError.invalidConfiguration("Node references must be unique and fit in 32-bit indices.")
        }
        guard
            graph.nodes.allSatisfy({ n in
                [n.x, n.y, n.width, n.height, n.center.x, n.center.y].allSatisfy { $0.isFinite && abs($0) < 1e15 }
                    && n.width >= 0 && n.height >= 0
            })
        else {
            throw OrganicLayoutError.invalidConfiguration(
                "Finite coordinates within ±1e15 and nonnegative dimensions are required."
            )
        }
        positions = graph.nodes.map { SIMD2($0.center.x, $0.center.y) }
        fixed = graph.nodes.map { n in
            (n.metadata[GraphMetadataKeys.fixed] as? Bool == true
                || (scope == .subset && n.metadata[GraphMetadataKeys.layoutSubset] as? Bool != true)) ? 1 : 0
        }
        // Stable seed, shared by all backends. Deliberately not .NET Random's implementation.
        if scatter && graph.nodes.allSatisfy({ $0.x == 0 && $0.y == 0 }) {
            var random = SplitMix64(seed: 42)
            for i in positions.indices where fixed[i] == 0 {
                positions[i] = SIMD2(
                    random.unitFloat() * 1_000 + graph.nodes[i].width / 2,
                    random.unitFloat() * 1_000 + graph.nodes[i].height / 2
                )
            }
        }
        let adjacency = Adjacency(graph)
        offsets = [0]
        neighbors = []
        for adjacent in adjacency.neighbors {
            guard neighbors.count + adjacent.count < Int(UInt32.max) else {
                throw OrganicLayoutError.invalidConfiguration("Adjacency must fit in 32-bit indices.")
            }
            neighbors.append(contentsOf: adjacent.map(UInt32.init))
            offsets.append(UInt32(neighbors.count))
        }
    }
}

struct SplitMix64 {
    var seed: UInt64

    mutating func unitFloat() -> Float {
        seed &+= 0x9E37_79B9_7F4A_7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }
}

func repulsiveForce(
    _ point: SIMD2<Float>,
    _ other: SIMD2<Float>,
    index: Int,
    otherIndex: Int,
    strength: Float
) -> SIMD2<Float> {
    var delta = point - other
    var squared = delta.x * delta.x + delta.y * delta.y
    if squared < 0.01 {
        let sign: Float = index > otherIndex ? 1 : -1
        delta = SIMD2(repeating: 0.1 * sign)
        squared = 0.02
    }
    if squared > 250_000 { return .zero }
    return delta * (strength / squared)
}

func cpuStep(
    _ state: ForceState,
    parameters: ForceParameters,
    temperature: Float,
    theta: Float?
) throws -> [SIMD2<Float>] {
    var result = state.positions
    let tree = theta.map { ForceTree(state.positions, theta: $0) }
    for i in state.positions.indices where state.fixed[i] == 0 {
        if i % 64 == 0 { try Task.checkCancellation() }
        let point = state.positions[i]
        var force = SIMD2<Float>.zero
        if let tree {
            force = tree.force(on: i, strength: parameters.repulsionSquared)
        } else {
            for j in state.positions.indices where i != j {
                force += repulsiveForce(
                    point,
                    state.positions[j],
                    index: i,
                    otherIndex: j,
                    strength: parameters.repulsionSquared
                )
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
