import Foundation
import SwiftGraph

struct Row: Codable {
    var operation: String; var nodes: Int; var edges: Int; var backend: String
    var medianMilliseconds: Double; var minMilliseconds: Double; var maxMilliseconds: Double
}
struct Report: Codable { var device: String; var iterations: Int; var trials: Int; var rows: [Row] }
func fixture(_ count: Int, bundling: Bool) -> LayoutGraph {
    let g = LayoutGraph()
    for i in 0..<count {
        let n = LayoutNode(id: String(i), width: 30, height: 20)
        n.center = bundling ? Point(x: i % 2 == 0 ? 0 : 400, y: Double(i / 2 % 100) * 2) :
            Point(x: Double((i * 137 + 29) % 997), y: Double((i * 263 + 47) % 991))
        g.addNode(n)
    }
    if bundling {
        for i in stride(from: 0, to: count - 1, by: 2) { g.addEdge(LayoutEdge(source: g.nodes[i], target: g.nodes[i + 1])) }
    } else {
        for i in 1..<count {
            g.addEdge(LayoutEdge(source: g.nodes[(i - 1) / 2], target: g.nodes[i]))
            if i > 7 && i % 3 == 0 { g.addEdge(LayoutEdge(source: g.nodes[i - 7], target: g.nodes[i])) }
        }
    }
    return g
}
func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
let executor = LayoutExecutor()
var rows: [Row] = [], device = "Metal unavailable"
for bundling in [false, true] {
    for count in (bundling ? [256, 1_024, 2_048] : [256, 1_024, 4_096]) {
        for backend in [LayoutBackend.cpu, .metal] {
            let organic = OrganicLayoutOperation(backend: backend, executor: executor)
            organic.configuration.iterations = 30
            let bundle = EdgeBundlingOperation(backend: backend, executor: executor)
            let operation: any AsyncLayoutAlgorithm = bundling ? bundle : organic
            try await operation.applyLayoutAsync(fixture(count, bundling: bundling))
            var times: [Double] = []
            for _ in 0..<3 {
                let g = fixture(count, bundling: bundling), start = ContinuousClock.now
                try await operation.applyLayoutAsync(g)
                times.append(ms(start.duration(to: .now)))
            }
            times.sort()
            let metrics = bundling ? bundle.lastMetrics : organic.lastMetrics
            device = metrics?.deviceName ?? device
            let row = Row(operation: bundling ? "bundling" : "organic", nodes: count,
                edges: fixture(count, bundling: bundling).edges.count, backend: backend.rawValue,
                medianMilliseconds: times[1], minMilliseconds: times[0], maxMilliseconds: times[2])
            rows.append(row)
            FileHandle.standardError.write(Data("\(row.operation) \(count) nodes \(backend): \(times[1]) ms\n".utf8))
        }
    }
}
let report = Report(device: device, iterations: 30, trials: 3, rows: rows)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(report)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "metal-backend-results.json"))
