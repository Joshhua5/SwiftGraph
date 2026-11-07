import SwiftUI

/// Sidebar of examples grouped by category, with the selected layout in the detail pane.
public struct GalleryView: View {
    private enum Item: Hashable {
        case example(GraphExample.ID)
        case topology(TopologyFile)
    }

    @State private var selection: Item? = GraphExample.all.first.map { .example($0.id) }
    @State private var topologies = TopologyLibrary.scan()

    public init() {}

    private var categories: [(String, [GraphExample])] {
        var order: [String] = []
        var grouped: [String: [GraphExample]] = [:]
        for example in GraphExample.all {
            if grouped[example.category] == nil { order.append(example.category) }
            grouped[example.category, default: []].append(example)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(categories, id: \.0) { category, examples in
                    Section(category) {
                        ForEach(examples) { Text($0.title).tag(Item.example($0.id)) }
                    }
                }
                Section("Production Topologies") {
                    ForEach(topologies) { Text($0.name).tag(Item.topology($0)) }
                    if topologies.isEmpty {
                        Text("No .json files in \(TopologyLibrary.directory.path)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button { topologies = TopologyLibrary.scan() } label: {
                        Label("Rescan Topologies", systemImage: "arrow.clockwise")
                    }
                    .help("Rescan the Topologies folder")
                }
            }
        } detail: {
            switch selection {
            case .example(let id):
                if let example = GraphExample.all.first(where: { $0.id == id }) {
                    // Fresh identity per example so the detail view's cached snapshot resets on selection.
                    GraphExampleView(example: example).id(example.id)
                }
            case .topology(let file):
                TopologyView(file: file).id(file.id)
            case nil:
                Text("Select an example").foregroundStyle(.secondary)
            }
        }
    }
}
