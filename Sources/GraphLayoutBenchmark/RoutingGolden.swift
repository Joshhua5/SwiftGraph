import Foundation
import SwiftGraph

/// Routes a placed prefix of a topology file with each CPU router and dumps every path exactly, so routing
/// optimizations can be checked for bit-identical output. Stage timings go to stderr.
///
///     graph-layout-benchmark --routing-golden --topology docs/graph-topology.json --edge-limits 150,300 \
///         --routers polyline,bus,channel,bsp,parallel --dump golden.json
private struct GoldenTopology: Decodable {
    struct Node: Decodable { var parent: Int? }

    struct Edge: Decodable {
        var source: Int
        var target: Int
    }

    var nodes: [Node]
    var edges: [Edge]

    func makeGraph(edgeLimit: Int) throws -> LayoutGraph {
        let graph = LayoutGraph()
        let groups = Set(nodes.compactMap(\.parent))
        for index in nodes.indices {
            let node = LayoutNode(id: "\(index)", width: 80, height: 32)
            node.isGroup = groups.contains(index)
            if node.isGroup { node.groupFrame = GroupFrameOptions(headerSize: Size(width: 80, height: 20)) }
            node.center = Point(x: Float(index % 16) * 120, y: Float(index / 16) * 80)
            graph.addNode(node)
        }
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent { try graph.moveNode(graph.nodes[index], to: graph.nodes[parent]) }
        }
        for edge in edges.prefix(edgeLimit) {
            graph.addEdge(LayoutEdge(source: graph.nodes[edge.source], target: graph.nodes[edge.target]))
        }
        return graph
    }
}

private struct GoldenCase: Codable {
    var name: String
    var milliseconds: Double

    /// Node bounds then edge paths, as "x,y" with round-trip-exact Float descriptions.
    var nodes: [String]
    var paths: [[String]]
}

private func describe(_ p: Point) -> String { "\(p.x),\(p.y)" }

private func router(_ name: String) -> (any EdgeRouter)? {
    switch name {
    case "polyline": PolylineEdgeRouter()
    case "bus": BusEdgeRouter()
    case "channel": ChannelEdgeRouter()
    case "bsp": BspEdgeRouter()
    case "parallel": ParallelEdgeRouter()
    default: nil
    }
}

func runRoutingGolden(_ arguments: [String]) async throws {
    func option(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
    let topologyPath = option("--topology") ?? "docs/graph-topology.json"
    let limits = (option("--edge-limits") ?? "150,300").split(separator: ",").compactMap { Int($0) }
    let routers = (option("--routers") ?? "polyline,bus,channel,bsp,parallel").split(separator: ",").map(String.init)
    let patterns = (option("--patterns") ?? "enterpriseArchitecture").split(separator: ",")
        .compactMap { LayoutPatternType(rawValue: String($0)) }
    guard routers.allSatisfy({ router($0) != nil }) else { throw LayoutExecutionError.invalidInput("Unknown router") }
    let topology = try JSONDecoder()
        .decode(GoldenTopology.self, from: Data(contentsOf: URL(fileURLWithPath: topologyPath)))
    var cases: [GoldenCase] = []

    func record(_ name: String, _ graph: LayoutGraph, _ work: () async throws -> Void) async throws {
        let start = ContinuousClock.now
        let (_, stages) = try await withLayoutStageProfiling { try await work() }
        let elapsed = start.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        FileHandle.standardError.write(Data("\(name): \(String(format: "%.1f", ms)) ms\n".utf8))
        for stage in stages where stage.totalSeconds * 1000 >= 1 {
            let line =
                "    \(stage.path.joined(separator: " / ")): \(String(format: "%.1f", stage.totalSeconds * 1000)) ms x\(stage.callCount)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        cases.append(
            GoldenCase(
                name: name,
                milliseconds: ms,
                nodes: graph.nodes.map {
                    "\(describe(Point(x: $0.bounds.left, y: $0.bounds.top))) \(describe(Point(x: $0.bounds.right, y: $0.bounds.bottom)))"
                },
                paths: graph.edges.map {
                    $0.path.map(describe) + [
                        "label \(describe(Point(x: $0.labelBounds.left, y: $0.labelBounds.top))) \(describe(Point(x: $0.labelBounds.right, y: $0.labelBounds.bottom)))"
                    ]
                }
            )
        )
    }

    for limit in limits {
        for pattern in patterns {
            let graph = try topology.makeGraph(edgeLimit: limit)
            try await record("\(limit) pattern \(pattern.rawValue)", graph) {
                try await LayoutBuilder.create(graph).applyPattern(pattern, backend: .cpu).applyAsync()
            }
        }
        // Routers run on one CPU placement so they share their input exactly.
        let placed = try topology.makeGraph(edgeLimit: limit)
        try await LayoutBuilder.create(placed).applyPattern(.enterpriseArchitecture, backend: .cpu).applyAsync()
        let centers = placed.nodes.map(\.center)
        for name in routers {
            for (node, center) in zip(placed.nodes, centers) { node.center = center }
            for edge in placed.edges { edge.path = [] }
            // Every name in `routers` was checked against `router(_:)` before any case ran.
            try await record("\(limit) router \(name)", placed) { router(name)!.routeEdges(placed) }
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(cases)
    if let path = option("--dump") { try data.write(to: URL(fileURLWithPath: path)) }
}
