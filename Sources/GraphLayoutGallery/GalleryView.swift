import SwiftGraph
import SwiftUI

/// Sidebar of examples grouped by category, with the selected layout in the detail pane.
public struct GalleryView: View {
    private enum Item: Hashable {
        case example(GraphExample.ID)
        case topology(TopologyFile)
    }

    @State private var selection: Item? = GraphExample.all.first.map { .example($0.id) }
    @State private var topologies = TopologyLibrary.scan()
    @State private var backend: LayoutBackend = .cpu

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
                        ForEach(examples) { ExampleRow(example: $0).tag(Item.example($0.id)) }
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
                    GraphExampleView(example: example, backend: $backend).id(example.id)
                }
            case .topology(let file):
                TopologyView(file: file, backend: $backend).id(file.id)
            case nil:
                Text("Select an example").foregroundStyle(.secondary)
            }
        }
    }
}

/// A sidebar row with an info button that opens a popover explaining the example.
private struct ExampleRow: View {
    let example: GraphExample
    @State private var showsInfo = false

    var body: some View {
        HStack {
            Text(example.title)
            Spacer()
            if let info = example.info {
                Button { showsInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                }
                // Borderless so clicking the button doesn't also select the row.
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About \(example.title)")
                .accessibilityLabel("About \(example.title)")
                .popover(isPresented: $showsInfo, arrowEdge: .trailing) {
                    ExampleInfoView(title: example.title, category: example.category, info: info)
                }
            }
        }
    }
}

/// Popover content: what an example is designed for, when to use it, and when not to.
private struct ExampleInfoView: View {
    let title: String
    let category: String
    let info: ExampleInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(category).font(.caption).foregroundStyle(.secondary)
            }
            section("Designed for", systemImage: "scope", text: info.designedFor)
            section("When to use", systemImage: "checkmark.circle", text: info.whenToUse)
            section("Avoid when", systemImage: "exclamationmark.triangle", text: info.avoidWhen)
        }
        .padding()
        .frame(width: 320, alignment: .leading)
    }

    private func section(_ heading: String, systemImage: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(heading, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
