import Foundation
import SwiftGraph

/// A production graph exported as compact topology JSON (the same format as `Tests/Fixtures/graph-topology.json`):
/// array positions are node IDs, and `parent`/`source`/`target` are zero-based indices into `nodes`.
struct ProductionTopology: Decodable, Sendable {
    struct Node: Decodable, Sendable { var parent: Int? }
    struct Edge: Decodable, Sendable {
        var source: Int
        var target: Int
        var bidirectional: Bool
    }
    var nodes: [Node]
    var edges: [Edge]

    struct InvalidTopology: Error, CustomStringConvertible { var description: String }

    static func load(from url: URL) throws -> ProductionTopology {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func makeGraph() throws -> LayoutGraph {
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent, !nodes.indices.contains(parent) {
                throw InvalidTopology(description: "Node \(index) has invalid parent index \(parent)")
            }
        }
        for index in nodes.indices {
            var cursor: Int? = index, seen = Set<Int>()
            while let current = cursor {
                guard seen.insert(current).inserted else { throw InvalidTopology(description: "Cyclic parent hierarchy at node \(index)") }
                cursor = nodes[current].parent
            }
        }
        for (index, edge) in edges.enumerated() {
            guard nodes.indices.contains(edge.source), nodes.indices.contains(edge.target) else {
                throw InvalidTopology(description: "Edge \(index) has invalid endpoint indices \(edge.source), \(edge.target)")
            }
        }

        let graph = LayoutGraph(), groups = Set(nodes.compactMap(\.parent))
        for index in nodes.indices {
            let node = LayoutNode(id: "\(index)", width: 80, height: 32)
            node.isGroup = groups.contains(index)
            if node.isGroup { node.groupFrame = GroupFrameOptions(headerSize: Size(width: 80, height: 20)) }
            // Deterministic starting positions, so presets that start from current geometry are reproducible.
            node.center = Point(x: Float(index % 16) * 120, y: Float(index / 16) * 80)
            graph.addNode(node)
        }
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent { try graph.moveNode(graph.nodes[index], to: graph.nodes[parent]) }
        }
        for edge in edges {
            // One route per record; bidirectionality is drawn as a second arrowhead, not a reverse edge.
            graph.addEdge(LayoutEdge(source: graph.nodes[edge.source], target: graph.nodes[edge.target], data: edge))
        }
        return graph
    }
}

// MARK: - Library folder

/// A topology JSON file found in the repository's `Topologies` folder.
struct TopologyFile: Identifiable, Hashable, Sendable {
    var url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum TopologyLibrary {
    /// `<repo>/Topologies`, resolved from this source file so the app and previews read the live folder
    /// (new files appear on rescan without rebuilding). `SWIFTGRAPH_TOPOLOGIES` overrides the location.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["SWIFTGRAPH_TOPOLOGIES"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // GraphLayoutGallery
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Topologies", isDirectory: true)
    }

    static func scan() -> [TopologyFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "json" }
            .map { TopologyFile(url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Configurable layout and routing

/// Placement for a topology: either a complete `LayoutPatternType` preset, or a single algorithm
/// wrapped in recursive group layout so the topology's nested groups are respected.
enum TopologyLayout: Hashable, Sendable, Identifiable {
    case preset(LayoutPatternType)
    case algorithm(Algorithm)

    enum Algorithm: String, CaseIterable, Sendable {
        case hierarchical = "Hierarchical", organic = "Organic", tree = "Tree", radialTree = "Radial Tree"
        case balloon = "Balloon", circular = "Circular", orthogonal = "Orthogonal", barycenter = "Barycenter"

        func make() -> any LayoutAlgorithm {
            switch self {
            case .hierarchical: HierarchicalLayoutAlgorithm()
            case .organic: OrganicLayoutAlgorithm()
            case .tree: TreeLayoutAlgorithm()
            case .radialTree: RadialTreeLayoutAlgorithm()
            case .balloon: BalloonLayoutAlgorithm()
            case .circular: CircularLayoutAlgorithm()
            case .orthogonal: OrthogonalLayoutAlgorithm()
            case .barycenter: BarycenterLayoutAlgorithm()
            }
        }
    }

    static let all: [TopologyLayout] = LayoutPatternType.allCases.map(preset) + Algorithm.allCases.map(algorithm)
    static let `default` = TopologyLayout.preset(.enterpriseArchitecture)

    var id: String { title }
    var title: String {
        switch self {
        case .preset(let pattern): pattern.rawValue
        case .algorithm(let algorithm): algorithm.rawValue
        }
    }
}

/// Edge routing applied after placement. `.layoutDefault` keeps a preset's own routes
/// (or polyline for bare algorithms); anything else re-routes the placed graph.
enum TopologyRouting: String, CaseIterable, Hashable, Sendable, Identifiable {
    case layoutDefault = "Layout Default"
    case straight = "Straight"
    case polyline = "Polyline"
    case channel = "Orthogonal Channel"
    case orthogonalGrouped = "Orthogonal Grouped"
    case bsp = "BSP"
    case octilinear = "Octilinear"
    case bundled = "Bundled"
    case curves = "Curve Fitting"

    var id: String { rawValue }

    func apply(to builder: LayoutBuilder, after layout: TopologyLayout) {
        switch self {
        case .layoutDefault:
            if case .preset = layout { return }
            builder.routePolyline()
        case .straight:
            builder.transform { graph in
                for edge in graph.edges { edge.path = [edge.source.center, edge.target.center] }
            }
        case .polyline: builder.routePolyline()
        case .channel: builder.routeChannel()
        case .orthogonalGrouped: builder.routeOrthogonalGrouped()
        case .bsp: builder.routeBsp()
        case .octilinear: builder.routeOctilinear()
        case .bundled: builder.routePolyline().routeWithBundling()
        case .curves: builder.routePolyline().routeCurveFitting()
        }
        builder.routeSelfLoops().clipEdgeEndpoints()
    }
}

extension GraphExample {
    /// A gallery example that reads `file` and lays it out with the chosen configuration.
    /// The ID encodes the configuration so changing a picker re-renders the view.
    static func topology(_ file: TopologyFile, layout: TopologyLayout, routing: TopologyRouting) -> GraphExample {
        let url = file.url
        return GraphExample(
            id: "topology|\(file.name)|\(layout.id)|\(routing.id)", title: file.name, category: "Production Topologies",
            summary: "\(layout.title) layout · \(routing.rawValue) routing",
            makeGraph: { try ProductionTopology.load(from: url).makeGraph() },
            configure: { builder in
                switch layout {
                case .preset(let pattern): builder.applyPattern(pattern)
                case .algorithm(let algorithm): builder.wrapWithRecursiveGroups(algorithm.make())
                }
                routing.apply(to: builder, after: layout)
            })
    }
}
