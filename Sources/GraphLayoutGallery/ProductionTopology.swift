import Foundation
import SwiftGraph
import SwiftGraphUI

/// A production graph exported as compact topology JSON (the same format as `Tests/Fixtures/graph-topology.json`):
/// array positions are node IDs, and `parent`/`source`/`target` are zero-based indices into `nodes`.
struct ProductionTopology: Decodable, Sendable {
    struct Node: Decodable, Sendable { var parent: Int? }
    struct Edge: Decodable, Sendable, GraphEdgeDescriptor {
        var source: Int
        var target: Int
        var bidirectional: Bool

        var isBidirectional: Bool { bidirectional }
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
            if node.isGroup {
                node.groupFrame = GroupFrameOptions(
                    padding: LayoutInsets(top: 16, left: 20, bottom: 20, right: 20),
                    headerSize: Size(width: 80, height: 22)
                )
            }
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

/// A topology JSON file found in the repository's `Topologies` or `docs` folder.
struct TopologyFile: Identifiable, Hashable, Sendable {
    var url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum TopologyLibrary {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // GraphLayoutGallery
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repository root
    }

    /// Primary topology directory (`<repo>/Topologies`, or `SWIFTGRAPH_TOPOLOGIES` if set).
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["SWIFTGRAPH_TOPOLOGIES"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return repoRoot.appendingPathComponent("Topologies", isDirectory: true)
    }

    private static var searchDirectories: [URL] {
        var dirs: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SWIFTGRAPH_TOPOLOGIES"], !override.isEmpty {
            dirs.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        dirs += [
            repoRoot.appendingPathComponent("Topologies", isDirectory: true),
            repoRoot.appendingPathComponent("docs", isDirectory: true),
            repoRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true),
        ]
        return dirs
    }

    static func scan() -> [TopologyFile] {
        var seenNames = Set<String>()
        var files: [TopologyFile] = []
        for dir in searchDirectories {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension.lowercased() == "json" {
                let file = TopologyFile(url: url)
                guard !seenNames.contains(file.name),
                      (try? ProductionTopology.load(from: url)) != nil else { continue }
                seenNames.insert(file.name)
                files.append(file)
            }
        }
        return files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func resolve(named name: String) -> TopologyFile {
        if let found = scan().first(where: { $0.name == name }) {
            return found
        }
        return TopologyFile(url: directory.appendingPathComponent("\(name).json"))
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

        func make(routesEdges: Bool = true, backend: LayoutBackend = .cpu) -> any AsyncLayoutAlgorithm {
            switch self {
            case .hierarchical:
                let hierarchical = HierarchicalLayoutOperation(backend: backend)
                hierarchical.configuration.routesEdges = routesEdges
                return hierarchical
            case .organic:
                let organic = OrganicLayoutOperation(backend: backend)
                organic.configuration.iterations = 300
                return organic
            case .tree:
                return TreeLayoutOperation(style: .tree, backend: backend)
            case .radialTree:
                return RadialLayoutOperation(style: .tree, backend: backend)
            case .balloon:
                return TreeLayoutOperation(style: .balloon, backend: backend)
            case .circular:
                return BasicLayoutOperation(style: .circular, backend: backend)
            case .orthogonal:
                return BasicLayoutOperation(style: .orthogonal, backend: backend)
            case .barycenter:
                return BarycenterLayoutOperation(backend: backend)
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

    private func separateEdgesIfSmall(_ builder: LayoutBuilder, backend: LayoutBackend) {
        builder.transformAsync { graph in
            guard graph.edges.count <= 150 else { return }
            try await RoutingLayoutOperation(.edgeSeparation, backend: backend).applyLayoutAsync(graph)
        }
    }

    func apply(to builder: LayoutBuilder, after layout: TopologyLayout, backend: LayoutBackend = .cpu) {
        switch self {
        case .layoutDefault:
            if case .preset = layout { return }
            builder.routeSelfLoops(backend: backend).clipEdgeEndpoints(backend: backend)
                .transform { if $0.edges.count <= 150 { PortDistributor().routeEdges($0) } }
            return
        case .straight:
            builder.transform { graph in
                for edge in graph.edges { edge.path = [edge.source.center, edge.target.center] }
            }
        case .polyline:
            builder.routePolyline(backend: backend)
        case .channel:
            builder.routeChannel(backend: backend)
            separateEdgesIfSmall(builder, backend: backend)
        case .orthogonalGrouped:
            builder.routeOrthogonalGrouped(backend: backend)
            separateEdgesIfSmall(builder, backend: backend)
        case .bsp:
            builder.routeBsp(backend: backend)
            separateEdgesIfSmall(builder, backend: backend)
        case .octilinear:
            builder.routeOctilinear(backend: backend)
        case .bundled:
            builder.routePolyline(backend: backend).routeWithBundling(backend: backend)
        case .curves:
            builder.routePolyline(backend: backend).clipEdgeEndpoints(backend: backend)
                .transform { if $0.edges.count <= 150 { PortDistributor().routeEdges($0) } }
                .routeCurveFitting(backend: backend)
            builder.routeSelfLoops(backend: backend).clipEdgeEndpoints(backend: backend)
            return
        }
        builder.routeSelfLoops(backend: backend).clipEdgeEndpoints(backend: backend)
            .transform { if $0.edges.count <= 150 { PortDistributor().routeEdges($0) } }
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
            configure: { builder, backend in
                switch layout {
                case .preset(let pattern):
                    builder.applyPattern(pattern, backend: backend)
                case .algorithm(let algorithm):
                    let keepDefaultRoutes = (routing == .layoutDefault)
                    builder.wrapWithRecursiveGroups(
                        algorithm.make(routesEdges: keepDefaultRoutes, backend: backend),
                        backend: backend
                    ) { groups in
                        groups.routesEdges = keepDefaultRoutes
                        groups.optimizeIncomingEdges = false
                    }
                }
                routing.apply(to: builder, after: layout, backend: backend)
            })
    }
}
