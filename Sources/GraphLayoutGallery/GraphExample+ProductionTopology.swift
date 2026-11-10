import Foundation
import SwiftGraph
import SwiftGraphUI

extension GraphExample {
    /// A gallery example that reads `file` and lays it out with the chosen configuration.
    /// The ID encodes the configuration so changing a picker re-renders the view.
    static func topology(_ file: TopologyFile, layout: TopologyLayout, routing: TopologyRouting) -> GraphExample {
        let url = file.url
        return GraphExample(
            id: "topology|\(file.name)|\(layout.id)|\(routing.id)",
            title: file.name,
            category: "Production Topologies",
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
            }
        )
    }
}
