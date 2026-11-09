import SwiftGraph
import SwiftGraphUI
import SwiftUI

/// Lays out one example asynchronously and draws the result using `SwiftGraphUI`.
struct GraphExampleView: View {
    let example: GraphExample
    var showsHeader = true

    private var externalBackend: Binding<LayoutBackend>?
    private var prerenderedResult: Result<GraphSnapshot, any Error>?
    @State private var ownedBackend: LayoutBackend = .cpu
    @State private var snapshot: GraphSnapshot?
    @State private var showLabels = true
    @State private var viewport = GraphViewport()

    private var backend: LayoutBackend {
        externalBackend?.wrappedValue ?? ownedBackend
    }

    private var backendBinding: Binding<LayoutBackend> {
        externalBackend ?? $ownedBackend
    }

    init(example: GraphExample, backend: Binding<LayoutBackend>? = nil, showsHeader: Bool = true) {
        self.example = example
        self.externalBackend = backend
        self.showsHeader = showsHeader
    }

    /// Starts with an already computed layout, so static preview snapshots never show the spinner.
    init(
        example: GraphExample,
        backend: Binding<LayoutBackend>? = nil,
        showsHeader: Bool = true,
        prerendered result: Result<GraphSnapshot, any Error>
    ) {
        self.init(example: example, backend: backend, showsHeader: showsHeader)
        self.prerenderedResult = result
        if case .success(let value) = result {
            _snapshot = State(initialValue: value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader { header }
            GraphView(
                id: example.id,
                backend: backend,
                viewport: $viewport,
                showLabels: showLabels,
                prerendered: prerenderedResult,
                onSnapshotChange: { snapshot = $0 },
                makeGraph: example.makeGraph,
                configure: example.configure
            )
        }
        .padding()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(example.title).font(.title2.bold())
                Text(example.summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let snapshot {
                let leafCount = snapshot.nodes.filter { !$0.isGroup }.count
                let groupCount = snapshot.nodes.count - leafCount
                let nodeSummary = groupCount > 0 ? "\(leafCount) nodes · \(groupCount) groups" : "\(leafCount) nodes"
                Text("\(nodeSummary) · \(snapshot.edges.count) edges · \(snapshot.duration.formatted(.units(allowed: [.milliseconds], width: .narrow)))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Picker("Backend", selection: backendBinding) {
                Text("CPU").tag(LayoutBackend.cpu)
                Text("Metal").tag(LayoutBackend.metal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help("Layout Execution Backend (CPU vs Metal)")
            HStack(spacing: 4) {
                Button {
                    viewport.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom Out")

                Button {
                    viewport.reset()
                } label: {
                    Text("\(Int((viewport.zoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 38)
                }
                .help("Reset Zoom & Pan")

                Button {
                    viewport.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom In")
            }
            .controlSize(.small)
            Toggle("Labels", isOn: $showLabels).toggleStyle(.button).controlSize(.small)
        }
    }
}
