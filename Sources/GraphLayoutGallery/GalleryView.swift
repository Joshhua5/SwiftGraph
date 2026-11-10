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
    /// The example whose info sheet is showing, if any.
    @State private var infoExample: GraphExample?

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
                        ForEach(examples) { example in
                            ExampleRow(example: example) { infoExample = example }
                                .tag(Item.example(example.id))
                        }
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
                    Button {
                        topologies = TopologyLibrary.scan()
                    } label: {
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
        .sheet(item: $infoExample) { example in
            if let info = example.info {
                ExampleInfoView(title: example.title, category: example.category, info: info)
            }
        }
    }
}

/// A sidebar row with an info button that opens a sheet explaining the example.
private struct ExampleRow: View {
    let example: GraphExample
    let showInfo: () -> Void

    var body: some View {
        HStack {
            Text(example.title)
            Spacer()
            if example.info != nil {
                Button(action: showInfo) {
                    Image(systemName: "info.circle")
                }
                // Borderless so clicking the button doesn't also select the row.
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About \(example.title)")
                .accessibilityLabel("About \(example.title)")
            }
        }
    }
}

/// Sheet content: what an example is designed for, when to use it, and when not to.
private struct ExampleInfoView: View {
    let title: String
    let category: String
    let info: ExampleInfo

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(category).font(.subheadline).foregroundStyle(.secondary)
            }
            section("Designed for", systemImage: "scope", text: info.designedFor)
            section("When to use", systemImage: "checkmark.circle", text: info.whenToUse)
            section("Avoid when", systemImage: "exclamationmark.triangle", text: info.avoidWhen)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func section(_ heading: String, systemImage: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(heading, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
