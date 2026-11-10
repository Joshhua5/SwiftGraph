import CoreGraphics
import Foundation
import SwiftGraph
import SwiftGraphUI

enum SampleGraphs {
    /// Adds a node with a width derived from its name, roughly matching the renderer's font.
    @discardableResult
    static func node(_ graph: LayoutGraph, _ id: String, in group: LayoutNode? = nil) throws -> LayoutNode {
        let node = LayoutNode(id: id, width: Float(max(74, id.count * 8 + 26)), height: 36)
        if let group { try graph.addNode(node, to: group) } else { graph.addNode(node) }
        return node
    }

    static func connect(_ graph: LayoutGraph, _ pairs: [(String, String)], labels: [String?] = []) {
        let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        for (index, (source, target)) in pairs.enumerated() {
            guard let s = byID[source], let t = byID[target] else { continue }
            let label = labels.indices.contains(index) ? labels[index] : nil
            graph.addEdge(LayoutEdge(source: s, target: t, data: label))
        }
    }

    /// A build pipeline: a layered DAG with a few skip edges and labels.
    static func buildPipeline() throws -> LayoutGraph {
        let g = LayoutGraph()
        for id in [
            "Checkout", "Resolve", "Lint", "Compile", "Unit Tests", "UI Tests", "Package", "Sign", "Notarize",
            "Publish",
        ] {
            try node(g, id)
        }
        connect(
            g,
            [
                ("Checkout", "Resolve"), ("Checkout", "Lint"), ("Resolve", "Compile"), ("Lint", "Compile"),
                ("Compile", "Unit Tests"), ("Compile", "UI Tests"), ("Compile", "Package"),
                ("Unit Tests", "Sign"), ("UI Tests", "Sign"), ("Package", "Sign"), ("Sign", "Notarize"),
                ("Notarize", "Publish"), ("Checkout", "Publish"),
            ],
            labels: [nil, nil, "deps", nil, nil, nil, "archive", nil, nil, nil, nil, "ticket", "tag"]
        )
        return g
    }

    /// A small social network with clusters and bridges between them.
    static func socialNetwork() throws -> LayoutGraph {
        let g = LayoutGraph()
        let people = [
            "Ava", "Ben", "Cleo", "Dev", "Eli", "Fay", "Gus", "Hana", "Ivo", "Jun", "Kai", "Lea", "Mo", "Nia", "Oto",
        ]
        for id in people { try node(g, id) }
        connect(
            g,
            [
                ("Ava", "Ben"), ("Ava", "Cleo"), ("Ben", "Cleo"), ("Cleo", "Dev"), ("Dev", "Ava"),
                ("Eli", "Fay"), ("Fay", "Gus"), ("Gus", "Eli"), ("Gus", "Hana"), ("Hana", "Eli"),
                ("Ivo", "Jun"), ("Jun", "Kai"), ("Kai", "Ivo"), ("Kai", "Lea"), ("Lea", "Ivo"),
                ("Mo", "Nia"), ("Nia", "Oto"), ("Oto", "Mo"),
                ("Dev", "Eli"), ("Hana", "Ivo"), ("Lea", "Mo"), ("Oto", "Ava"),
            ]
        )
        return g
    }

    /// A balanced organisation tree.
    static func organisation() throws -> LayoutGraph {
        let g = LayoutGraph()
        let reports: [(String, [String])] = [
            ("CEO", ["CTO", "CFO", "COO"]),
            ("CTO", ["Platform", "Apps", "Research"]),
            ("CFO", ["Finance", "Legal"]),
            ("COO", ["Support", "Sales", "Ops"]),
            ("Apps", ["iOS", "macOS"]),
        ]
        try node(g, "CEO")
        for (_, children) in reports { for child in children { try node(g, child) } }
        connect(g, reports.flatMap { manager, children in children.map { (manager, $0) } })
        return g
    }

    /// A mind map radiating from one topic.
    static func mindMap() throws -> LayoutGraph {
        let g = LayoutGraph()
        let branches: [(String, [String])] = [
            ("Layout", ["Hierarchical", "Organic", "Tree", "Radial"]),
            ("Routing", ["Polyline", "Channel", "BSP", "Bundling"]),
            ("Analysis", ["PageRank", "Clusters"]),
            ("Metal", ["Forces", "Placement"]),
        ]
        try node(g, "SwiftGraph")
        for (branch, leaves) in branches {
            try node(g, branch)
            for leaf in leaves { try node(g, leaf) }
        }
        connect(g, branches.map { ("SwiftGraph", $0.0) } + branches.flatMap { b, leaves in leaves.map { (b, $0) } })
        return g
    }

    /// A ring of services with a few chords, plus a self-loop.
    static func serviceRing() throws -> LayoutGraph {
        let g = LayoutGraph()
        let ids = ["Gateway", "Auth", "Users", "Orders", "Billing", "Inventory", "Shipping", "Search", "Mail", "Audit"]
        for id in ids { try node(g, id) }
        var pairs = zip(ids, ids.dropFirst() + [ids[0]]).map { ($0, $1) }
        pairs += [
            ("Gateway", "Orders"), ("Orders", "Shipping"), ("Auth", "Audit"), ("Search", "Inventory"),
            ("Billing", "Billing"),
        ]
        connect(g, pairs)
        return g
    }

    /// A circuit-like graph suited to orthogonal placement and channel routing.
    static func circuit() throws -> LayoutGraph {
        let g = LayoutGraph()
        for id in ["Power", "Regulator", "MCU", "Flash", "Sensor", "Radio", "Antenna", "LED", "Button", "USB"] {
            try node(g, id)
        }
        connect(
            g,
            [
                ("Power", "Regulator"), ("USB", "Regulator"), ("Regulator", "MCU"), ("MCU", "Flash"), ("Sensor", "MCU"),
                ("MCU", "Radio"), ("Radio", "Antenna"), ("MCU", "LED"), ("Button", "MCU"), ("USB", "MCU"),
                ("Regulator", "Sensor"), ("Regulator", "Radio"),
            ]
        )
        return g
    }

    /// A service architecture with nested, titled groups and cross-group dependencies.
    static func groupedArchitecture() throws -> LayoutGraph {
        let g = LayoutGraph()
        func frame(_ title: String) -> GroupFrameOptions {
            GroupFrameOptions(
                padding: LayoutInsets(top: 16, left: 24, bottom: 20, right: 24),
                headerSize: Size(width: Float(title.count * 8 + 28), height: 26)
            )
        }
        let client = try g.addGroup(id: "Clients", frame: frame("Clients"))
        let backend = try g.addGroup(id: "Backend", frame: frame("Backend"))
        let services = try g.addGroup(id: "Services", parent: backend, frame: frame("Services"))
        let storage = try g.addGroup(id: "Storage", parent: backend, frame: frame("Storage"))
        for id in ["iOS App", "Web App", "CLI"] { try node(g, id, in: client) }
        try node(g, "API Gateway", in: backend)
        for id in ["Accounts", "Catalog", "Orders"] { try node(g, id, in: services) }
        for id in ["Postgres", "Redis", "Blob Store"] { try node(g, id, in: storage) }
        try node(g, "Analytics")
        connect(
            g,
            [
                ("iOS App", "API Gateway"), ("Web App", "API Gateway"), ("CLI", "API Gateway"),
                ("API Gateway", "Accounts"), ("API Gateway", "Catalog"), ("API Gateway", "Orders"),
                ("Accounts", "Postgres"), ("Orders", "Postgres"), ("Catalog", "Redis"), ("Catalog", "Blob Store"),
                ("Orders", "Analytics"),
            ]
        )
        return g
    }

    /// Bipartite producer/consumer traffic, a good fit for edge bundling.
    static func bipartite() throws -> LayoutGraph {
        let g = LayoutGraph()
        let producers = (1...6).map { "Producer \($0)" }
        let consumers = (1...6).map { "Consumer \($0)" }
        for id in producers + consumers { try node(g, id) }
        for (i, node) in g.nodes.enumerated() {
            node.x = i < 6 ? 0 : 600
            node.y = Float(i % 6) * 70
        }
        var pairs: [(String, String)] = []
        for (i, p) in producers.enumerated() {
            pairs += [(p, consumers[i]), (p, consumers[(i + 2) % 6]), (p, consumers[(i + 3) % 6])]
        }
        connect(g, pairs)
        for edge in g.edges { edge.path = [edge.source.center, edge.target.center] }
        return g
    }
}

// MARK: - Catalogue
