import Foundation
import SwiftGraph

/// Measures how much a router's output depends on the order of `graph.edges`: one placement is routed in its own
/// order and in several seeded shuffles, and the quality metrics and per-edge route stability are compared.
///
///     graph-layout-benchmark --routing-order --topology docs/graph-topology.json --edge-limits 150,300 \
///         --routers polyline,channel --shuffles 8 [--channel-rounds 3] [--separate]
///
/// Also routes eight seeded random scenes (15 nodes, about 25 edges) so small graphs are covered.
func runRoutingOrder(_ arguments: [String]) async throws {
    func option(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
    let topologyPath = option("--topology") ?? "docs/graph-topology.json"
    let limits = (option("--edge-limits") ?? "150,300").split(separator: ",").compactMap { Int($0) }
    let routers = (option("--routers") ?? "polyline,channel").split(separator: ",").map(String.init)
    let shuffles = Int(option("--shuffles") ?? "8") ?? 8
    let rounds = option("--channel-rounds").flatMap { Int($0) }
    // Measures what a preset draws: the channel router has no built-in separator, so presets add one.
    let separates = arguments.contains("--separate")
    guard routers.allSatisfy({ makeOrderRouter($0, rounds: nil) != nil }) else {
        throw LayoutExecutionError.invalidInput("Unknown router")
    }
    let topology = try JSONDecoder()
        .decode(GoldenTopology.self, from: Data(contentsOf: URL(fileURLWithPath: topologyPath)))
    var scenes: [(name: String, graph: LayoutGraph)] = []
    for limit in limits {
        let graph = try topology.makeGraph(edgeLimit: limit)
        try await LayoutBuilder.create(graph).applyPattern(.enterpriseArchitecture, backend: .cpu).applyAsync()
        scenes.append(("topology \(limit)", graph))
    }
    scenes.append(contentsOf: (0..<8).map { ("random \($0)", randomScene(round: $0)) })
    for name in routers {
        print("router \(name)")
        print("scene             | crossings mean [min-max] | bends mean [min-max] | overlap mean [min-max] | "
              + "length mean | stable | ms mean")
        var totals = (crossingSpread: 0, overlapSpread: 0.0, stable: 0.0, milliseconds: 0.0, scenes: 0)
        for scene in scenes {
            let graph = scene.graph
            let original = graph.edges
            var samples: [OrderSample] = []
            var reference: [ObjectIdentifier: [Point]] = [:]
            for k in 0...shuffles {
                var order = original
                if k > 0 {
                    var seed = ShuffleSeed(state: UInt64(k) &* 0x9E37_79B9_7F4A_7C15)
                    order.shuffle(using: &seed)
                }
                graph.edges = order
                for edge in order { edge.path = [] }
                // Every name in `routers` was checked against `makeOrderRouter(_:rounds:)` above.
                let router = makeOrderRouter(name, rounds: rounds)!
                let start = ContinuousClock.now
                router.routeEdges(graph)
                if separates && name == "channel" { EdgeSeparator().finishRoutes(graph) }
                let elapsed = milliseconds(start.duration(to: .now))
                var sample = OrderSample(original, milliseconds: elapsed)
                if k == 0 {
                    for edge in original { reference[ObjectIdentifier(edge)] = edge.path }
                } else {
                    let same = original.filter { reference[ObjectIdentifier($0)] == $0.path }.count
                    sample.stable = Double(same) / Double(max(1, original.count))
                }
                samples.append(sample)
            }
            graph.edges = original
            let shuffled = samples.dropFirst()
            func range<T: Comparable>(_ values: [T]) -> String { "\(values.min()!)-\(values.max()!)" }
            let crossings = samples.map(\.crossings)
            let bends = samples.map(\.bends)
            let overlap = samples.map { Int($0.overlap.rounded()) }
            let stable = shuffled.map(\.stable).reduce(0, +) / Double(max(1, shuffled.count))
            let time = samples.map(\.milliseconds).reduce(0, +) / Double(samples.count)
            print(
                scene.name.padding(toLength: 17, withPad: " ", startingAt: 0)
                    + " | \(mean(crossings)) [\(range(crossings))]"
                    + " | \(mean(bends)) [\(range(bends))]"
                    + " | \(mean(overlap)) [\(range(overlap))]"
                    + " | \(Int(samples.map(\.length).reduce(0, +) / Float(samples.count)))"
                    + " | \(String(format: "%.0f%%", stable * 100))"
                    + " | \(String(format: "%.1f", time))"
            )
            totals.crossingSpread += crossings.max()! - crossings.min()!
            totals.overlapSpread += Double(overlap.max()! - overlap.min()!)
            totals.stable += stable
            totals.milliseconds += time
            totals.scenes += 1
        }
        let n = Double(totals.scenes)
        print(
            "summary: crossing spread sum \(totals.crossingSpread), overlap spread sum \(Int(totals.overlapSpread)), "
                + "mean stable \(String(format: "%.0f%%", totals.stable / n * 100)), "
                + "total ms per order \(String(format: "%.0f", totals.milliseconds))"
        )
    }
}

/// `rounds` overrides the channel router's negotiation rounds.
private func makeOrderRouter(_ name: String, rounds: Int?) -> (any EdgeRouter)? {
    switch name {
    case "polyline":
        return PolylineEdgeRouter()
    case "channel":
        let router = ChannelEdgeRouter()
        if let rounds { router.negotiationRounds = rounds }
        return router
    default:
        return nil
    }
}

private func mean(_ values: [Int]) -> String {
    String(format: "%.1f", Double(values.reduce(0, +)) / Double(max(1, values.count)))
}

/// The seeded scenes of `channelCrossingsStayLowOnSeededRandomGraphs`.
private func randomScene(round: Int) -> LayoutGraph {
    var seed = UInt64(12345 + round)
    func next() -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(seed >> 33)
    }
    let graph = LayoutGraph()
    var nodes: [LayoutNode] = []
    for i in 0..<15 {
        let node = LayoutNode(id: "n\(i)", width: Float(60 + next() % 60), height: Float(30 + next() % 30))
        node.x = Float(i % 5) * 190 + Float(next() % 50)
        node.y = Float(i / 5) * 150 + Float(next() % 50)
        graph.addNode(node)
        nodes.append(node)
    }
    for _ in 0..<(22 + round) {
        let s = next() % nodes.count
        let t = next() % nodes.count
        if s != t { graph.addEdge(LayoutEdge(source: nodes[s], target: nodes[t])) }
    }
    return graph
}

/// Route quality of one routing: proper crossings between different edges, bends, collinear shared length and
/// total length.
private struct OrderSample {
    var crossings = 0
    var bends = 0
    var overlap: Float = 0
    var length: Float = 0
    var stable = 1.0
    var milliseconds: Double

    init(_ edges: [LayoutEdge], milliseconds: Double) {
        self.milliseconds = milliseconds
        let paths = edges.filter { $0.source !== $0.target && $0.path.count >= 2 }.map(\.path)
        func cross(_ a: Point, _ b: Point) -> Float { a.x * b.y - a.y * b.x }
        let segments = paths.enumerated().flatMap { k, path in zip(path, path.dropFirst()).map { (k, $0, $1) } }
        for path in paths {
            for i in path.indices.dropFirst().dropLast()
            where abs(cross(path[i] - path[i - 1], path[i + 1] - path[i])) > 1e-4 { bends += 1 }
        }
        for (_, a, b) in segments { length += (b - a).length }
        for (n, (k, a, b)) in segments.enumerated() {
            let u = b - a
            let lu = u.length
            guard lu > 1e-4 else { continue }
            for (l, c, d) in segments[(n + 1)...] where l != k {
                let v = d - c
                let denominator = cross(u, v)
                if abs(denominator) > 1e-6 * lu * max(v.length, 1e-4) {
                    let t = cross(c - a, v) / denominator
                    let s = cross(c - a, u) / denominator
                    if t > 1e-5 && t < 1 - 1e-5 && s > 1e-5 && s < 1 - 1e-5 { crossings += 1 }
                    continue
                }
                // Parallel: shared length when the two lie on one line.
                guard abs(cross(u, c - a)) / lu < 0.5 else { continue }
                let direction = u / lu
                let p = (c - a).x * direction.x + (c - a).y * direction.y
                let q = (d - a).x * direction.x + (d - a).y * direction.y
                overlap += max(0, min(lu, max(p, q)) - max(0, min(p, q)))
            }
        }
    }
}

private struct ShuffleSeed: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
