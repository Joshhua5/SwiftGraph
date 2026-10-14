import Foundation
import GraphEvaluationSupport
import SwiftGraph

private struct ProductionRow: Codable {
    var operation: String
    var fixture: String
    var nodes: Int
    var edges: Int
    var requestedBackend: String
    var trial: Int
    var cold: Bool
    var actualBackends: [String] = []
    var fallbackReasons: [String] = []
    var cpuStages: [String] = []
    var metalStages: [String] = []
    var totalMilliseconds: Double?
    var operationMilliseconds: Double?
    var routingMilliseconds: Double?
    var computeMilliseconds: Double?
    var gpuMilliseconds: Double?
    var cpuPreparationMilliseconds: Double?
    var qualityPreparationMilliseconds: Double?
    var qualitySolverMilliseconds: Double?
    var qualityEvaluationMilliseconds: Double?
    var solverIterations: Int = 0
    var submittedBatches: Int = 0
    var completedBatches: Int = 0
    var bufferAllocations: Int = 0
    var bufferReuses: Int = 0
    var cachedBufferBytes: Int = 0
    var device: String?
    var skipped: String?
}

private struct ProductionComparison: Codable {
    var operation: String
    var fixture: String
    var nodes: Int
    var edges: Int
    var cpuWarmMedianMilliseconds: Double
    var metalWarmMedianMilliseconds: Double
    var warmSpeedupRatio: Double
    var gpuUtilizationFraction: Double
    var outputComparison: OutputComparisonSummary
}

private struct ProductionReport: Codable {
    var os: String
    var processorCount: Int
    var routing: String
    var rows: [ProductionRow]
    var comparisons: [ProductionComparison] = []
    var notes: [String]
}

private final class RecordingOrganic: AsyncLayoutAlgorithm {
    let operation: OrganicLayoutOperation
    var metrics: [LayoutExecutionMetrics] = []
    var iterations = 0
    init(_ operation: OrganicLayoutOperation) { self.operation = operation }
    func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        try await operation.applyLayoutAsync(graph)
        if let metric = operation.lastMetrics { metrics.append(metric) }
        iterations += operation.lastDiagnostics?.solverIterations ?? 0
    }
}

private func productionGraph(_ count: Int, kind: String) -> LayoutGraph {
    let graph = LayoutGraph()
    for i in 0..<count {
        let node = LayoutNode(id: "n\(i)", width: 20 + Double(i % 4) * 5, height: 20)
        node.center = Point(x: Double((i * 137 + 29) % 997), y: Double((i * 263 + 47) % 991))
        if kind == "pinned" && i % 16 == 0 { node.metadata[GraphMetadataKeys.fixed] = true }
        if kind == "subset" { node.metadata[GraphMetadataKeys.layoutSubset] = i % 3 == 0 }
        graph.addNode(node)
    }
    for i in 1..<count {
        if kind == "isolated" { continue }
        let base = kind == "components" || kind == "groups" ? (i / 32) * 32 : 0
        if i == base { continue }
        graph.addEdge(LayoutEdge(source: graph.nodes[base + (i - base - 1) / 2], target: graph.nodes[i]))
        if kind == "dense" {
            for delta in 1...min(8, i) {
                graph.addEdge(LayoutEdge(source: graph.nodes[i - delta], target: graph.nodes[i]))
            }
        }
    }
    if kind == "groups" {
        let leaves = graph.nodes
        graph.root.children = []
        for start in stride(from: 0, to: count, by: 32) {
            let group = LayoutNode(id: "group\(start)", width: 0, height: 0); group.isGroup = true
            group.children = Array(leaves[start..<min(start + 32, count)])
            for child in group.children { child.parent = group }
            graph.addNode(group)
        }
    }
    return graph
}

/// Measures the public executor and quality pipeline, separately from the legacy Float spike.
func runProductionBenchmark(_ arguments: [String]) async throws {
    func option(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
    let sizes = (option("--sizes") ?? "64,256,1024").split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 }
    let operations = (option("--operations") ?? "organic,barycenter,bundling").split(separator: ",").map(String.init)
    let fixtures = (option("--fixtures") ?? "sparse,dense,components,pinned,subset,groups").split(separator: ",").map(String.init)
    let backends = (option("--backends") ?? "cpu,automatic,metal").split(separator: ",").map(String.init)
    let trials = max(1, Int(option("--trials") ?? "3") ?? 3)
    let iterations = option("--iterations").flatMap(Int.init)
    let routing = option("--routing") ?? "polyline"
    let basicOperations = BasicLayoutStyle.allCases.map(\.rawValue)
    let treeOperations = TreeLayoutStyle.allCases.map(\.rawValue)
    let routingOperations = RoutingKind.allCases.map { "route-" + $0.rawValue }
    let supportedOperations = ["organic", "barycenter", "bundling", "radial", "radial-star", "radial-tree",
        "hierarchical", "seriesParallel", "directed", "pageRank", "clusters", "swimlane", "multiPage"]
        + basicOperations + treeOperations + routingOperations
    guard !sizes.isEmpty, operations.allSatisfy({ supportedOperations.contains($0) }),
          fixtures.allSatisfy({ ["sparse", "dense", "components", "pinned", "subset", "groups", "isolated"].contains($0) }),
          backends.allSatisfy({ LayoutBackend(rawValue: $0) != nil }),
          ["none", "polyline"].contains(routing), iterations.map({ $0 >= 0 }) ?? true else {
        throw LayoutExecutionError.invalidInput("Invalid production benchmark arguments")
    }
    if arguments.contains("--require-metal") && !LayoutExecutor.isMetalAvailable { throw OrganicLayoutError.metalUnavailable }
    var rows: [ProductionRow] = []
    var comparisons: [ProductionComparison] = []
    for size in sizes {
        for fixture in fixtures {
            for operation in operations {
                var finalGraphs: [LayoutBackend: LayoutGraph] = [:]
                for requested in backends {
                    let backend = LayoutBackend(rawValue: requested)!, executor = LayoutExecutor()
                    for trial in 0..<trials {
                        let graph = productionGraph(size, kind: fixture)
                        var row = ProductionRow(operation: operation, fixture: fixture, nodes: graph.nodes.count, edges: graph.edges.count,
                                                requestedBackend: requested, trial: trial, cold: trial == 0)
                        if backend == .metal && !LayoutExecutor.isMetalAvailable {
                            row.skipped = "Metal device unavailable"; rows.append(row); break
                        }
                        let before = await executor.statistics(), start = ContinuousClock.now
                        var metrics: [LayoutExecutionMetrics] = []
                        switch operation {
                        case "organic":
                            var configuration = OrganicLayoutConfiguration()
                            if let iterations { configuration.iterations = iterations }
                            if fixture == "subset" { configuration.scope = .subset }
                            let recorder = RecordingOrganic(OrganicLayoutOperation(backend: backend, executor: executor, configuration: configuration))
                            if fixture == "groups" { try await RecursiveGroupLayoutOperation(recorder).applyLayoutAsync(graph) }
                            else { try await recorder.applyLayoutAsync(graph) }
                            metrics = recorder.metrics; row.solverIterations = recorder.iterations
                        case "barycenter":
                            var configuration = BarycenterLayoutConfiguration()
                            if let iterations { configuration.iterations = iterations }
                            let layout = BarycenterLayoutOperation(backend: backend, executor: executor, configuration: configuration)
                            try await layout.applyLayoutAsync(graph)
                            metrics = layout.lastMetrics.map { [$0] } ?? []; row.solverIterations = configuration.iterations
                        case "radial", "radial-star", "radial-tree":
                            let style: RadialLayoutStyle = operation == "radial-star" ? .star : operation == "radial-tree" ? .tree : .radial
                            let layout = RadialLayoutOperation(style: style, backend: backend, executor: executor)
                            try await layout.applyLayoutAsync(graph)
                            metrics = layout.lastExecutionMetrics
                        case "bundling":
                            var configuration = EdgeBundlingConfiguration()
                            if let iterations { configuration.iterations = iterations }
                            let layout = EdgeBundlingOperation(backend: backend, executor: executor, configuration: configuration)
                            try await layout.applyLayoutAsync(graph)
                            metrics = layout.lastMetrics.map { [$0] } ?? []; row.solverIterations = configuration.iterations
                        default:
                            let layout: any LayoutExecutionReporting
                            if let style = BasicLayoutStyle(rawValue: operation) {
                                layout = BasicLayoutOperation(style: style, backend: backend, executor: executor)
                            } else if let style = TreeLayoutStyle(rawValue: operation) {
                                layout = TreeLayoutOperation(style: style, backend: backend, executor: executor)
                            } else if operation.hasPrefix("route-"), let kind = RoutingKind(rawValue: String(operation.dropFirst(6))) {
                                // Supply usable paths and labels for edge-finishing operations.
                                for edge in graph.edges {
                                    edge.path = [edge.source.center, (edge.source.center + edge.target.center) / 2 + Point(x: 20, y: 30), edge.target.center]
                                    edge.labelBounds = Rect(x: edge.path[1].x, y: edge.path[1].y, width: 40, height: 15)
                                }
                                layout = RoutingLayoutOperation(kind, backend: backend, executor: executor)
                            } else {
                                switch operation {
                                case "hierarchical": layout = HierarchicalLayoutOperation(backend: backend, executor: executor)
                                case "seriesParallel": layout = SeriesParallelLayoutOperation(backend: backend, executor: executor)
                                case "directed": layout = DirectedLayoutAsyncOperation(backend: backend, executor: executor)
                                case "pageRank", "clusters":
                                    var pageRank = PageRankConfiguration(); if let iterations { pageRank.iterations = iterations }
                                    layout = AnalysisLayoutOperation(operation == "pageRank" ? .pageRank : .clusters,
                                        backend: backend, executor: executor, pageRank: pageRank)
                                case "swimlane": layout = SwimlaneLayoutOperation(backend: backend, executor: executor)
                                default: layout = MultiPageLayoutOperation(backend: backend, executor: executor)
                                }
                            }
                            try await layout.applyLayoutAsync(graph); metrics = layout.lastExecutionMetrics
                        }
                        row.operationMilliseconds = milliseconds(start.duration(to: .now))
                        let routingStart = ContinuousClock.now
                        // Bundling is already a routing operation; do not overwrite its result.
                        if operation != "bundling" && !operation.hasPrefix("route-") && routing != "none" {
                            PolylineEdgeRouter().routeEdges(graph)
                            SelfLoopRouter().routeEdges(graph)
                        }
                        row.routingMilliseconds = milliseconds(routingStart.duration(to: .now))
                        row.totalMilliseconds = milliseconds(start.duration(to: .now))
                        row.actualBackends = metrics.map { $0.backend.rawValue }
                        row.fallbackReasons = metrics.compactMap { $0.fallbackReason?.rawValue }
                        row.cpuStages = metrics.flatMap(\.cpuStages)
                        row.metalStages = metrics.flatMap(\.metalStages)
                        row.computeMilliseconds = metrics.reduce(0) { $0 + $1.computeSeconds * 1000 }
                        row.cpuPreparationMilliseconds = metrics.reduce(0) { $0 + $1.cpuPreparationSeconds * 1000 }
                        let gpu = metrics.compactMap(\.gpuSeconds)
                        row.gpuMilliseconds = gpu.isEmpty ? nil : gpu.reduce(0, +) * 1000
                        let phases = metrics.compactMap(\.qualityPhases)
                        if !phases.isEmpty {
                            row.qualityPreparationMilliseconds = phases.reduce(0) { $0 + $1.preparationSeconds * 1000 }
                            row.qualitySolverMilliseconds = phases.reduce(0) { $0 + $1.solverSeconds * 1000 }
                            row.qualityEvaluationMilliseconds = phases.reduce(0) { $0 + $1.evaluationSeconds * 1000 }
                        }
                        let after = await executor.statistics()
                        row.submittedBatches = after.submittedBatches - before.submittedBatches
                        row.completedBatches = after.completedBatches - before.completedBatches
                        row.bufferAllocations = after.bufferAllocations - before.bufferAllocations
                        row.bufferReuses = after.bufferReuses - before.bufferReuses; row.cachedBufferBytes = after.cachedBufferBytes
                        row.device = metrics.compactMap(\.deviceName).first
                        rows.append(row)
                        if trial == trials - 1 {
                            finalGraphs[backend] = graph
                        }
                        FileHandle.standardError.write(Data("\(size) \(fixture) \(operation) \(requested) trial \(trial): \(row.totalMilliseconds!) ms\n".utf8))
                    }
                }
                if let cpuGraph = finalGraphs[.cpu], let metalGraph = finalGraphs[.metal] {
                    let cpuRows = rows.filter { $0.operation == operation && $0.fixture == fixture && $0.nodes == cpuGraph.nodes.count && $0.requestedBackend == "cpu" }
                    let metalRows = rows.filter { $0.operation == operation && $0.fixture == fixture && $0.nodes == metalGraph.nodes.count && $0.requestedBackend == "metal" }
                    let cpuWarm = (cpuRows.dropFirst().isEmpty ? cpuRows : Array(cpuRows.dropFirst())).compactMap(\.totalMilliseconds).sorted()
                    let metalWarm = (metalRows.dropFirst().isEmpty ? metalRows : Array(metalRows.dropFirst())).compactMap(\.totalMilliseconds).sorted()
                    let cpuMed = cpuWarm.isEmpty ? 0 : cpuWarm[cpuWarm.count / 2]
                    let metalMed = metalWarm.isEmpty ? 0 : metalWarm[metalWarm.count / 2]
                    let gpuMed = (metalRows.dropFirst().isEmpty ? metalRows : Array(metalRows.dropFirst())).compactMap(\.gpuMilliseconds).sorted().first ?? 0
                    let outputComparison = BackendBenchmarkEvaluation.compareGraphs(
                        id: "prod-\(operation)-\(fixture)-\(size)",
                        family: "production",
                        cpuGraph: cpuGraph,
                        metalGraph: metalGraph
                    )
                    comparisons.append(
                        ProductionComparison(
                            operation: operation,
                            fixture: fixture,
                            nodes: cpuGraph.nodes.count,
                            edges: cpuGraph.edges.count,
                            cpuWarmMedianMilliseconds: cpuMed,
                            metalWarmMedianMilliseconds: metalMed,
                            warmSpeedupRatio: metalMed > 0 ? cpuMed / metalMed : 0,
                            gpuUtilizationFraction: metalMed > 0 ? gpuMed / metalMed : 0,
                            outputComparison: outputComparison
                        )
                    )
                }
            }
        }
    }
    let report = ProductionReport(os: ProcessInfo.processInfo.operatingSystemVersionString,
        processorCount: ProcessInfo.processInfo.activeProcessorCount, routing: routing, rows: rows, comparisons: comparisons,
        notes: ["Release build required. First trial includes lazy pipeline setup; later trials reuse the executor.",
                "Production CPU uses Double; Metal uses Float. Organic includes full quality search and cleanup.",
                "Total includes the operation and selected routing; fixture construction and statistics queries are excluded.",
                "Grouped organic records every child operation. Other grouped fixtures are treated as flat inputs.",
                "Quality phases cover CPU preparation/preflight, candidate solver calls, and CPU cleanup/scoring.",
                "Radial operations include CPU obstacle repair even with --routing none; their Metal kernel selects clearance pairs.",
                "Cached bytes describe idle pooled buffers, not peak process or GPU memory.",
                "Comparisons measure node/edge geometry and quality deltas between the final CPU and Metal trial outputs."])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    if let path = option("--output") { try data.write(to: URL(fileURLWithPath: path)) }
    else { FileHandle.standardOutput.write(data); print() }
}
