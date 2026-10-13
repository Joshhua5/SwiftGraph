import Foundation
import SwiftGraph

struct RoutingFixture: Decodable, Sendable {
    struct Node: Decodable, Sendable { var id: String; var bounds: [Double]; var parent: String?; var group: Bool? }
    struct Edge: Decodable, Sendable {
        var source: String; var target: String
        var sourcePort: PortConstraint?; var targetPort: PortConstraint?
        var sourceCandidates: [PortConstraint]?; var targetCandidates: [PortConstraint]?
        var path: [[Double]]?
    }
    struct Expected: Decodable, Sendable {
        var paths: [[[Double]]]; var bounds: [[Double]]; var root: [Double]
        var global: [[[Double]]]; var local: [[[[Double]]]]
    }
    var name: String; var router: String; var nodes: [Node]; var edges: [Edge]; var config: [String: Double]; var expected: Expected
    func graph() -> LayoutGraph {
        let graph = LayoutGraph()
        let lookup = Dictionary(uniqueKeysWithValues: nodes.map { spec in
            let n = LayoutNode(id: spec.id, width: spec.bounds[2], height: spec.bounds[3]); n.x = spec.bounds[0]; n.y = spec.bounds[1]; n.isGroup = spec.group ?? false
            return (spec.id, n)
        })
        for spec in nodes {
            let n = lookup[spec.id]!
            if let parent = spec.parent { n.parent = lookup[parent]!; n.parent!.children.append(n) }
            graph.addNode(n)
        }
        for spec in edges {
            let e = LayoutEdge(source: lookup[spec.source]!, target: lookup[spec.target]!)
            e.sourcePort = spec.sourcePort ?? .none; e.targetPort = spec.targetPort ?? .none
            e.sourcePortCandidates = spec.sourceCandidates ?? []; e.targetPortCandidates = spec.targetCandidates ?? []
            e.path = (spec.path ?? []).map { Point(x: $0[0], y: $0[1]) }; graph.addEdge(e)
        }
        return graph
    }
    /// Every router now intentionally diverges from the C# reference paths (boundary ports, clipping at the first
    /// entry, widest-gap BSP cuts, checked grouped nudging); fixtures assert invariants instead. See docs/routing-parity.md.
    var divergesFromReference: Bool { true }
    func makeRouter() -> any EdgeRouter {
        switch router {
        case "channel":
            let r = ChannelEdgeRouter(); r.gridSize = Int(config["gridSize"] ?? 20); r.bendPenalty = Int(config["bendPenalty"] ?? 2); r.congestionPenalty = Int(config["congestionPenalty"] ?? 2); return r
        case "grouped":
            let r = OrthogonalGroupedEdgeRouter(); r.bundleSpacing = config["bundleSpacing"] ?? 10; r.obstacleMargin = config["obstacleMargin"] ?? 10; r.bendPenalty = config["bendPenalty"] ?? 100; return r
        case "polyline": let r = PolylineEdgeRouter(); r.padding = config["padding"] ?? 10; return r
        default: return BspEdgeRouter()
        }
    }
}

func loadRoutingFixtures() throws -> [RoutingFixture] {
    let url = Bundle.module.url(forResource: "routing-reference", withExtension: "json", subdirectory: "Fixtures")!
    return try JSONDecoder().decode([RoutingFixture].self, from: Data(contentsOf: url))
}
