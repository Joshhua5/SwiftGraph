import Foundation

final class AsyncPresetPlacement: LayoutExecutionReporting {
    private let configure: (LayoutBuilder) -> Void
    private let preservedKeys: [String]
    private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []

    init(preserving keys: [String] = [], _ configure: @escaping (LayoutBuilder) -> Void) {
        self.configure = configure
        preservedKeys = keys
    }

    func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastExecutionMetrics = []
        let old = graph.nodes.map(\.metadata)
        defer {
            for (node, values) in zip(graph.nodes, old) {
                for key in preservedKeys { node.metadata[key] = values[key] }
            }
        }
        let builder = LayoutBuilder.create(graph)
        configure(builder)
        try await builder.applyAsync()
        lastExecutionMetrics = builder.lastExecutionMetrics
    }
}
