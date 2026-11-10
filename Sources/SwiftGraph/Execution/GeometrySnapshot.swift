import Foundation

struct GeometrySnapshot: Sendable {
    struct Node: Sendable, Equatable {
        var bounds: Rect
        var fixed: Bool
        var selected: Bool
        var isGroup: Bool = false
    }

    struct Edge: Sendable {
        var source: Int
        var target: Int
        var index: Int
    }

    var nodes: [Node]
    var edges: [Edge]

    func makeGraph() -> LayoutGraph {
        let graph = LayoutGraph()
        for (i, state) in nodes.enumerated() {
            let n = LayoutNode(id: String(i), width: state.bounds.width, height: state.bounds.height)
            n.bounds = state.bounds
            n.isGroup = state.isGroup
            n.metadata[GraphMetadataKeys.fixed] = state.fixed
            n.metadata[GraphMetadataKeys.layoutSubset] = state.selected
            graph.addNode(n)
        }
        for edge in edges {
            graph.addEdge(LayoutEdge(source: graph.nodes[edge.source], target: graph.nodes[edge.target]))
        }
        return graph
    }

    func cpuOrganic(_ configuration: OrganicLayoutConfiguration) throws -> [Point] {
        let graph = makeGraph()
        let algorithm = OrganicLayoutAlgorithm(quality: configuration.quality)
        algorithm.preparedPositions = configuration.preparedPositions
        algorithm.initialization = configuration.initialization
        algorithm.nodeSeparation = configuration.nodeSeparation
        algorithm.scope = configuration.scope
        algorithm.iterations =
            configuration.quality == .quality ? Float(configuration.iterations) : configuration.iterationBudget
        algorithm.initialTemperature = configuration.initialTemperature
        algorithm.repulsionForce = configuration.repulsionForce
        algorithm.attractionForce = configuration.attractionForce
        try algorithm.applyLayout(graph)
        return graph.nodes.map(\.center)
    }

    func prepareMetal(
        configuration: OrganicLayoutConfiguration,
        fixed: [Bool],
        tolerance: Float
    ) throws -> (state: ForceState, origin: Point) {
        var centers = nodes.map { $0.bounds.center }
        if !configuration.preparedPositions && nodes.allSatisfy({ $0.bounds.x == 0 && $0.bounds.y == 0 }) {
            var random = SeededRandom()
            for i in nodes.indices where !fixed[i] {
                centers[i] = Point(
                    x: Float(random.next() * 1_000) + nodes[i].bounds.width / 2,
                    y: Float(random.next() * 1_000) + nodes[i].bounds.height / 2
                )
            }
        }
        guard
            let minX = centers.map(\.x).min(),
            let maxX = centers.map(\.x).max(),
            let minY = centers.map(\.y).min(),
            let maxY = centers.map(\.y).max()
        else {
            preconditionFailure("prepareMetal requires a non-empty snapshot; callers return early without nodes")
        }
        let origin = Point(x: minX + (maxX - minX) / 2, y: minY + (maxY - minY) / 2)
        let bound =
            Double(max(maxX - minX, maxY - minY) / 2) + Double(configuration.iterations)
            * Double(configuration.initialTemperature)
        var neighbors = Array(repeating: [UInt32](), count: nodes.count)
        for e in edges where e.source != e.target {
            neighbors[e.source].append(UInt32(e.target))
            neighbors[e.target].append(UInt32(e.source))
        }
        let degree = neighbors.map(\.count).max() ?? 0
        let forceBound =
            Double(nodes.count) * Double(configuration.repulsionForce) * Double(configuration.repulsionForce) * 10
            + Double(degree) * bound * 4 * Double(configuration.attractionForce)
        guard bound.isFinite, Float(bound).isFinite, Float(bound).ulp <= tolerance,
            forceBound.isFinite, forceBound < Double(sqrt(Float.greatestFiniteMagnitude)) / 4,
            configuration.initialTemperature.isFinite, configuration.attractionForce.isFinite
        else {
            throw LayoutExecutionError.precisionLimit
        }
        var flat: [UInt32] = []
        var offsets: [UInt32] = [0]
        for adjacent in neighbors {
            guard flat.count + adjacent.count < Int(UInt32.max) else {
                throw LayoutExecutionError.invalidInput("Too many edges for Metal indices.")
            }
            flat.append(contentsOf: adjacent)
            offsets.append(UInt32(flat.count))
        }
        return (
            ForceState(
                positions: centers.map { SIMD2($0.x - origin.x, $0.y - origin.y) },
                fixed: fixed.map { $0 ? 1 : 0 },
                offsets: offsets,
                neighbors: flat
            ), origin
        )
    }
}
