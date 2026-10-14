import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport
#if os(macOS)
import ImageIO
#endif

@Suite(.serialized) struct GraphTopologyRenderingTests {
    private struct RenderResult: Sendable {
        var id: String
        var snapshot: VisualSnapshot?
        var error: String?
    }

    #if os(macOS)
    private static func render(_ pattern: LayoutPatternType, topology: GraphTopology, output: URL) async -> RenderResult {
        let id = pattern.rawValue
        print("Rendering topology preset: \(id)")
        do {
            let graph = try topology.makeGraph()
            let identities = graph.nodes
            try await LayoutBuilder.create(graph).applyPattern(pattern).applyAsync()
            #expect(graph.nodes == identities, "\(id): node identities changed")
            #expect(graph.edges.count == topology.edges.count, "\(id): edges lost")
            let drawing = topology.drawing(graph)
            let item = VisualCase(id: id, family: "topology", title: "Topology / \(id)", configuration: ["pattern": id]) { drawing }
            let snapshot = VisualSnapshot(case: item, drawing: drawing)
            try VisualStorage.validate(snapshot)
            #expect(snapshot.edges.allSatisfy { $0.path.count >= 2 }, "\(id): missing routes")
            let stem = output.appendingPathComponent(id)
            try VisualStorage.writeJSON(snapshot, stem.appendingPathExtension("json"))
            try VisualRenderer.write(VisualScene(snapshot: snapshot, crossingJumps: false), to: stem)
            let source = try #require(CGImageSourceCreateWithURL(stem.appendingPathExtension("png") as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width > 0 && image.height > 0 && max(image.width, image.height) <= 2400)
            print("Rendered topology preset: \(id)")
            return RenderResult(id: id, snapshot: snapshot)
        } catch {
            Issue.record("\(id): \(error)")
            return RenderResult(id: id, error: String(describing: error))
        }
    }
    #endif

    @Test func loaderPreservesIndicesHierarchyAndDirections() throws {
        // Includes a forward parent reference, nested groups, disconnected nodes, and a self-loop.
        let topology = try JSONDecoder().decode(GraphTopology.self, from: Data("""
        {"nodes":[{"parent":2},{"parent":0},{},{}],"edges":[
          {"source":1,"target":3,"bidirectional":true},
          {"source":3,"target":3,"bidirectional":false}]}
        """.utf8))
        let graph = try topology.makeGraph()
        #expect(graph.nodes.map(\.id) == ["0", "1", "2", "3"])
        #expect(graph.nodes.map(\.isGroup) == [true, false, true, false])
        #expect(graph.nodes[0].parent === graph.nodes[2])
        #expect(graph.nodes[1].parent === graph.nodes[0])
        #expect(graph.root.children == [graph.nodes[2], graph.nodes[3]])
        #expect(graph.nodes[2].children == [graph.nodes[0]])
        #expect(graph.edges.count == 2)
        #expect(graph.edges[0].source === graph.nodes[1] && graph.edges[0].target === graph.nodes[3])
        #expect((graph.edges[0].data as? GraphTopology.Edge)?.bidirectional == true)
        #expect(graph.edges[1].source === graph.edges[1].target)
        let fresh = try topology.makeGraph()
        #expect(fresh.nodes[0] !== graph.nodes[0])
        #expect(fresh.nodes.map(\.bounds) == graph.nodes.map(\.bounds))
    }

    @Test(arguments: [
        "{\"nodes\":[{\"parent\":1}],\"edges\":[]}",
        "{\"nodes\":[{\"parent\":-1}],\"edges\":[]}",
        "{\"nodes\":[{\"parent\":0}],\"edges\":[]}",
        "{\"nodes\":[{\"parent\":1},{\"parent\":0}],\"edges\":[]}",
        "{\"nodes\":[{}],\"edges\":[{\"source\":0,\"target\":1,\"bidirectional\":false}]}",
        "{\"nodes\":[{}],\"edges\":[{\"source\":-1,\"target\":0,\"bidirectional\":true}]}"
    ])
    func loaderRejectsInvalidIndicesAndCycles(_ json: String) throws {
        let topology = try JSONDecoder().decode(GraphTopology.self, from: Data(json.utf8))
        #expect(throws: EvaluationError.self) { try topology.makeGraph() }
    }

    @Test func bidirectionalEdgesRenderTwoArrowheadsAndRoundTrip() throws {
        let topology = try JSONDecoder().decode(GraphTopology.self, from: Data("""
        {"nodes":[{},{}],"edges":[{"source":0,"target":1,"bidirectional":true}]}
        """.utf8))
        let graph = try topology.makeGraph()
        graph.edges[0].path = [graph.nodes[0].center, graph.nodes[1].center]
        let item = VisualCase(id: "directions", family: "topology", title: "Directions") { topology.drawing(graph) }
        let snapshot = VisualSnapshot(case: item, drawing: topology.drawing(graph))
        let decoded = try JSONDecoder().decode(VisualSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(decoded.edges[0].bidirectional == true)
        let scene = VisualScene(snapshot: decoded, crossingJumps: false)
        let arrows = scene.primitives.compactMap { primitive -> [Point]? in
            if case let .polygon(points, _) = primitive { return points }; return nil
        }
        #expect(arrows.count == 2)
        #expect(arrows.map { $0[0] } == [graph.nodes[1].center, graph.nodes[0].center])
        var directed = decoded; directed.edges[0].bidirectional = nil
        #expect(VisualComparison.compare(decoded, directed).changedEdges == ["e0"])
        #expect(VisualRenderer.svg(VisualScene(snapshot: directed)).components(separatedBy: "<polygon").count - 1 == 1)
    }

    @Test func bundledFixtureMatchesSuppliedTopology() throws {
        let topology = try GraphTopology.load()
        #expect(topology.nodes.count == 249)
        #expect(topology.edges.count == 2622)
        let graph = try topology.makeGraph()
        #expect(graph.nodes.filter(\.isGroup).count == 8)
        #expect(graph.nodes[200].parent === graph.nodes[199])
        #expect(graph.nodes[245].parent === graph.nodes[244])
        #expect(graph.nodes[248].parent === graph.root)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTGRAPH_RENDER_TOPOLOGY"] == "1"))
    func rendersTopologyInEverySupportedPreset() async throws {
        #if os(macOS)
        let environment = ProcessInfo.processInfo.environment
        let input = environment["SWIFTGRAPH_TOPOLOGY_INPUT"].map { URL(fileURLWithPath: $0) }
        let topology = try GraphTopology.load(from: input)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = environment["SWIFTGRAPH_TOPOLOGY_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(".build/visual/topology-\(UUID().uuidString)")
        try VisualStorage.prepareOutput(output)
        // Keep the precise input alongside its rendered evidence, including direction flags.
        let inputURL = try input ?? GraphTopology.bundledURL()
        try FileManager.default.copyItem(at: inputURL, to: output.appendingPathComponent("input.json"))
        var report = ["# Graph topology preset renders", "",
            "Input: \(topology.nodes.count) nodes, \(topology.edges.count) edges. Node labels are zero-based indices.", "",
            "Every preset uses its default CPU pipeline on a fresh graph. Parents become groups; bidirectional records use one route with two arrowheads.", "",
            "PNG previews are capped at 2400 pixels; SVGs retain full geometry for zooming. Crossing jump decoration is disabled for this dense graph. Overlaps and crossings are visual review findings, not pass/fail thresholds.", "",
            "![All presets](contact-sheet.png)", "", "| Preset | Result | PNG | SVG | Geometry |", "| --- | --- | --- | --- | --- |"]
        print("Topology render artifacts: \(output.path)")
        let patterns = LayoutPatternType.allCases
        let results = await withTaskGroup(of: RenderResult.self, returning: [String: RenderResult].self) { group in
            // Mutable graphs remain task-confined; only immutable snapshots cross tasks.
            // Bound concurrency so dense routing cannot launch all 17 workloads at once.
            let parallelism = min(4, patterns.count)
            for pattern in patterns.prefix(parallelism) {
                group.addTask { await Self.render(pattern, topology: topology, output: output) }
            }
            var next = parallelism, results: [String: RenderResult] = [:]
            for await result in group {
                results[result.id] = result
                if next < patterns.count {
                    let pattern = patterns[next]; next += 1
                    group.addTask { await Self.render(pattern, topology: topology, output: output) }
                }
            }
            return results
        }
        var snapshots: [VisualSnapshot] = []
        for pattern in patterns {
            let id = pattern.rawValue
            if let snapshot = results[id]?.snapshot {
                snapshots.append(snapshot)
                report.append("| \(id) | Rendered | [PNG](\(id).png) | [SVG](\(id).svg) | [JSON](\(id).json) |")
            } else {
                let error = (results[id]?.error ?? "Missing result").replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
                report.append("| \(id) | Failed: \(error) | | | |")
            }
        }
        if !snapshots.isEmpty {
            try VisualRenderer.write(VisualScene.contactSheet(snapshots, crossingJumps: false), to: output.appendingPathComponent("contact-sheet"))
        }
        try (report.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        #expect(Set(snapshots.map(\.id)) == Set(LayoutPatternType.allCases.map(\.rawValue)))
        #else
        // ImageIO PNG export is supported by the existing renderer on macOS only.
        #endif
    }
}
