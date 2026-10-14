import Foundation
import GraphEvaluationSupport
import SwiftGraph

struct Row: Codable {
    var nodes: Int
    var edges: Int
    var iterations: Int
    var backend: String
    var medianMilliseconds: Double
    var medianGPUMilliseconds: Double?
    var minMilliseconds: Double
    var maxMilliseconds: Double
}
struct Comparison: Codable {
    var nodes: Int
    var rmsDisplacementFromExact: Double
    var maxDisplacementFromExact: Double
    var backend: String
}
struct Report: Codable {
    var device: String
    var coordinateSpread: Double
    var os: String
    var cpuCount: Int
    var trials: Int
    var setupMilliseconds: [String: Double]
    var results: [Row]
    var comparisons: [Comparison]
    var notes: [String]
}
func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}
func fixture(_ count: Int) -> LayoutGraph {
    let graph = LayoutGraph()
    for i in 0..<count {
        let n = LayoutNode(id: "n\(i)", width: 30 + Double(i % 4) * 5, height: 20 + Double(i % 3) * 5)
        // A reproducible, dense 1000×1000 cloud, independent of backend initialization.
        n.center = Point(x: Double((i * 137 + 29) % 997) * coordinateSpread, y: Double((i * 263 + 47) % 991) * coordinateSpread)
        graph.addNode(n)
    }
    if count > 1 {
        for i in 1..<count {
            graph.addEdge(LayoutEdge(source: graph.nodes[(i - 1) / 2], target: graph.nodes[i]))
            if i > 7 && i % 3 == 0 { graph.addEdge(LayoutEdge(source: graph.nodes[i - 7], target: graph.nodes[i])) }
        }
    }
    return graph
}
func median(_ values: [Double]) -> Double { let v = values.sorted(); return v[v.count / 2] }

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1]
}
if args.contains("--compare-catalogue") {
    let forward = ["benchmark"] + args.filter { $0 != "--compare-catalogue" }
    exit(await VisualTool.run(forward))
}
if args.contains("--production") {
    try await runProductionBenchmark(args)
    exit(0)
}
let sizes = (option("--sizes") ?? "64,256,1024,4096").split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 }
let iterations = max(1, Int(option("--iterations") ?? "30") ?? 30)
let trials = max(1, Int(option("--trials") ?? "3") ?? 3)
let coordinateSpread = max(0.001, Double(option("--spread") ?? "1") ?? 1)
let selectedBackends = Set((option("--backends") ?? "cpuExact,cpuBarnesHut,metal").split(separator: ",").map(String.init))
if args.contains("--require-metal") && !AcceleratedOrganicLayoutAlgorithm.isMetalAvailable { throw OrganicLayoutError.metalUnavailable }
var algorithms: [AcceleratedOrganicLayoutAlgorithm] = [], setup: [String: Double] = [:]
for backend in OrganicBackend.allCases where selectedBackends.contains(backend.rawValue) {
    if backend == .metal && !AcceleratedOrganicLayoutAlgorithm.isMetalAvailable { continue }
    let start = ContinuousClock.now
    let algorithm = try AcceleratedOrganicLayoutAlgorithm(backend: backend)
    setup[backend.rawValue] = milliseconds(start.duration(to: .now))
    algorithm.iterations = iterations; algorithms.append(algorithm)
}
var rows: [Row] = [], comparisons: [Comparison] = []
for count in sizes {
    var outputs: [OrganicBackend: [Point]] = [:]
    for algorithm in algorithms {
        // Warm-up each size; initialization, graph construction and warm-up are outside measured passes.
        try algorithm.applyLayout(fixture(count))
        var times: [Double] = [], gpuTimes: [Double] = []
        for _ in 0..<trials {
            let graph = fixture(count)
            try algorithm.applyLayout(graph)
            guard let metrics = algorithm.lastMetrics else { fatalError("Missing metrics") }
            times.append(metrics.wallTimeSeconds * 1_000)
            if let gpu = metrics.gpuTimeSeconds { gpuTimes.append(gpu * 1_000) }
            outputs[algorithm.backend] = graph.nodes.map(\.center)
        }
        rows.append(Row(nodes: count, edges: fixture(count).edges.count, iterations: iterations, backend: algorithm.backend.rawValue,
                        medianMilliseconds: median(times), medianGPUMilliseconds: gpuTimes.isEmpty ? nil : median(gpuTimes),
                        minMilliseconds: times.min()!, maxMilliseconds: times.max()!))
        FileHandle.standardError.write(Data("\(count) nodes, \(algorithm.backend.rawValue): \(String(format: "%.2f", median(times))) ms\n".utf8))
    }
    if let exact = outputs[.cpuExact] {
        for algorithm in algorithms where algorithm.backend != .cpuExact {
            guard let points = outputs[algorithm.backend] else { continue }
            // Remove global translation when comparing shape.
            let centroidA = exact.reduce(Point.zero, +) / Double(count)
            let centroidB = points.reduce(Point.zero, +) / Double(count)
            let distances = zip(exact, points).map { (($0 - centroidA) - ($1 - centroidB)).length }
            comparisons.append(Comparison(nodes: count, rmsDisplacementFromExact: sqrt(distances.reduce(0) { $0 + $1 * $1 } / Double(count)),
                                          maxDisplacementFromExact: distances.max() ?? 0, backend: algorithm.backend.rawValue))
        }
    }
}
let report = Report(device: algorithms.compactMap(\.deviceName).first ?? "CPU-only run", coordinateSpread: coordinateSpread, os: ProcessInfo.processInfo.operatingSystemVersionString,
                    cpuCount: ProcessInfo.processInfo.activeProcessorCount, trials: trials, setupMilliseconds: setup, results: rows, comparisons: comparisons,
                    notes: ["Release build required for meaningful comparisons.", "CPU backends are single-threaded Swift; this is not a benchmark of Waring's parallel C# Barnes-Hut implementation.",
                            "All backends use Float. Metal uses exact all-pairs forces; Barnes-Hut approximates with theta 0.8.",
                            "Warm timings include preparation, allocations, CPU/GPU transfer, command submission and readback. Initialization/shader compilation is reported separately.",
                            "Displacement is not a visual quality metric. Iterative trajectories can diverge at the 500-unit force cutoff."])
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(report)
if let path = option("--output") { try data.write(to: URL(fileURLWithPath: path)) }
else { FileHandle.standardOutput.write(data); print() }
