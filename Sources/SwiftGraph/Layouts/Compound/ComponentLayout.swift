import Foundation

public final class ComponentLayout: LayoutAlgorithm {
    public var coreLayout: any LayoutAlgorithm
    public var componentSpacing: Float = 50
    public var preferredAspectRatio: Float = 1

    public init(_ coreLayout: any LayoutAlgorithm) { self.coreLayout = coreLayout }

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        let components = a.components()
        if components.count == 1 {
            try coreLayout.applyLayout(graph)
            return
        }
        var graphs: [LayoutGraph] = []
        let slices = LayoutStageScope.slices(components.map { Double($0.count) })
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            let g = subgraph(graph, nodes: component.map { a.nodes[$0] })
            try LayoutStageScope.run(
                "Component \(index + 1)/\(components.count)",
                from: slices[index].from,
                to: slices[index].to
            ) {
                try coreLayout.applyLayout(g)
            }
            let b = g.bounds
            translate(g, by: Point(x: -b.x, y: -b.y))
            graphs.append(g)
        }
        let shifts = packedTranslations(
            graphs.map(\.bounds),
            spacing: componentSpacing,
            aspectRatio: preferredAspectRatio
        )
        for (g, shift) in zip(graphs, shifts) { translate(g, by: shift) }
        graph.routeStyle = sharedRouteStyle(graphs)
    }
}
