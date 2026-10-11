import Foundation
import SwiftGraph
func fixture(_ n: Int, spread: Double) -> LayoutGraph {
 let g = LayoutGraph()
 for i in 0..<n {
  let v = LayoutNode(id: "\(i)", width: 30 + Double(i % 4) * 5, height: 20 + Double(i % 3) * 5)
  v.center = Point(x: Double((i * 137 + 29) % 997) * spread, y: Double((i * 263 + 47) % 991) * spread)
  g.addNode(v)
 }
 for i in 1..<n {
  g.addEdge(LayoutEdge(source: g.nodes[(i - 1) / 2], target: g.nodes[i]))
  if i > 7 && i % 3 == 0 { g.addEdge(LayoutEdge(source: g.nodes[i - 7], target: g.nodes[i])) }
 }
 return g
}
func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
struct Row: Codable { var nodes: Int; var spread: Double; var implementation: String; var medianMS: Double; var minMS: Double; var maxMS: Double }
struct Report: Codable { var device: String; var iterations: Int; var trials: Int; var rows: [Row] }
let gpu = try AcceleratedOrganicLayoutAlgorithm(backend: .metal); gpu.iterations = 30
let cpu = OrganicLayoutAlgorithm(); cpu.iterations = 30
var rows: [Row] = []
for spread in [1.0, 10.0] {
 for n in [64, 256, 1024, 4096] {
  for (name, algorithm): (String, any LayoutAlgorithm) in [("packageCPU", cpu), ("metal", gpu)] {
   try algorithm.applyLayout(fixture(n, spread: spread))
   var samples: [Double] = []
   for _ in 0..<3 {
    let g = fixture(n, spread: spread), start = ContinuousClock.now
    try algorithm.applyLayout(g)
    samples.append(ms(start.duration(to: .now)))
   }
   samples.sort()
   rows.append(Row(nodes: n, spread: spread, implementation: name, medianMS: samples[1], minMS: samples[0], maxMS: samples[2]))
   FileHandle.standardError.write(Data("\(n) nodes spread \(spread) \(name): \(samples[1]) ms\n".utf8))
  }
 }
}
let report = Report(device: gpu.deviceName ?? "unknown", iterations: 30, trials: 3, rows: rows)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(report)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "metal-integration-results.json"))
