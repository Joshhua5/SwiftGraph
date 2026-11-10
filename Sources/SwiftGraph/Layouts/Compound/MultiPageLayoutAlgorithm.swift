import Foundation

public final class MultiPageLayoutAlgorithm: LayoutAlgorithm {
    public var pageWidth: Float = 800
    public var pageHeight: Float = 1100
    public var pageSpacing: Float = 100
    public var coreLayout: any LayoutAlgorithm

    public init(_ coreLayout: (any LayoutAlgorithm)? = nil) {
        self.coreLayout = coreLayout ?? HierarchicalLayoutAlgorithm()
    }

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        let components = a.components()
        let slices = LayoutStageScope.slices(components.map { Double($0.count) })
        for (i, component) in components.enumerated() {
            try Task.checkCancellation()
            let g = subgraph(graph, nodes: component.map { a.nodes[$0] })
            try LayoutStageScope.run("Page \(i + 1)/\(components.count)", from: slices[i].from, to: slices[i].to) {
                try coreLayout.applyLayout(g)
            }
            let b = g.bounds
            translate(
                g,
                by: Point(
                    x: Float(i % 3) * (pageWidth + pageSpacing) + (pageWidth - b.width) / 2 - b.x,
                    y: Float(i / 3) * (pageHeight + pageSpacing) + (pageHeight - b.height) / 2 - b.y
                )
            )
        }
    }
}
