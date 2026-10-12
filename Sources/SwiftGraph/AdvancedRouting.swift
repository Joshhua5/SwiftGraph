import Foundation

public final class EdgeBundlingRouter: EdgeRouter {
    public var iterations = 30
    public var segments = 10
    public var k: Double = 0.1
    public var compatibilityThreshold: Double = 0.6
    public var bundlingDistance: Double = 500
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        let edges = graph.edges.filter { $0.source !== $0.target }
        let count = max(1, segments)
        let directions = edges.map { $0.target.center - $0.source.center }
        let lengths = directions.map(\.length), centers = edges.map { ($0.source.center + $0.target.center) / 2 }
        var points = edges.enumerated().map { i, e in (0...count).map { e.source.center + directions[i] * (Double($0) / Double(count)) } }
        var compatible = Array(repeating: [(Int, Bool)](), count: edges.count)
        for i in edges.indices where lengths[i] > 0.1 {
            for j in edges.indices where i != j && lengths[j] > 0.1 && (centers[i] - centers[j]).length <= bundlingDistance {
                let dot = (directions[i].x * directions[j].x + directions[i].y * directions[j].y) / (lengths[i] * lengths[j])
                if abs(dot) > compatibilityThreshold { compatible[i].append((j, dot < 0)) }
            }
        }
        if count > 1 {
            for iteration in 0..<max(0, iterations) {
                if Task.isCancelled { return }
                var next = points
                let step = 0.1 * (1 - Double(iteration) / Double(max(1, iterations)))
                for i in edges.indices {
                    let spring = lengths[i] > 0.1 ? max(0, k) / (lengths[i] * Double(count)) : 0
                    for p in 1..<count {
                        var force = (points[i][p - 1] + points[i][p + 1] - points[i][p] * 2) * spring
                        for (j, reversed) in compatible[i] {
                            let delta = points[j][reversed ? count - p : p] - points[i][p]
                            force = force + delta / sqrt(delta.lengthSquared + 0.0001)
                        }
                        next[i][p] = points[i][p] + force * step
                    }
                }
                points = next
            }
        }
        for i in edges.indices { edges[i].path = points[i] }
    }
}
