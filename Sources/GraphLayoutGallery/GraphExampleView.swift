import SwiftGraph
import SwiftUI

/// Lays out one example asynchronously and draws the result.
struct GraphExampleView: View {
    let example: GraphExample
    var showsHeader = true

    private var externalBackend: Binding<LayoutBackend>?
    @State private var ownedBackend: LayoutBackend = .cpu
    @State private var snapshot: GraphSnapshot?
    @State private var errorMessage: String?
    @State private var renderedBackend: LayoutBackend?
    @State private var showLabels = true
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var dragStartPan: CGSize = .zero

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
        _renderedBackend = State(initialValue: backend?.wrappedValue ?? .cpu)
        switch result {
        case .success(let value): _snapshot = State(initialValue: value)
        case .failure(let error): _errorMessage = State(initialValue: String(describing: error))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader { header }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.canvasBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                if let snapshot {
                    GraphCanvas(snapshot: snapshot, showLabels: showLabels, zoom: zoom, pan: pan)
                        .padding(8)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    pan = CGSize(
                                        width: dragStartPan.width + value.translation.width,
                                        height: dragStartPan.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in dragStartPan = pan }
                        )
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in zoom = max(0.4, min(6.0, baseZoom * value)) }
                                .onEnded { _ in baseZoom = zoom }
                        )
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary).padding()
                } else {
                    ProgressView("Laying out…")
                }
            }
        }
        .padding()
        .task(id: "\(example.id)|\(backend)") {
            let currentBackend = backend
            guard renderedBackend != currentBackend || (snapshot == nil && errorMessage == nil) else { return }
            errorMessage = nil
            do {
                snapshot = try await example.render(backend: currentBackend)
                renderedBackend = currentBackend
            } catch is CancellationError {
                return
            } catch {
                errorMessage = String(describing: error)
                renderedBackend = currentBackend
            }
        }
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
                    zoom = max(0.4, zoom / 1.25); baseZoom = zoom
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom Out")

                Button {
                    zoom = 1; baseZoom = 1; pan = .zero; dragStartPan = .zero
                } label: {
                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 38)
                }
                .help("Reset Zoom & Pan")

                Button {
                    zoom = min(6.0, zoom * 1.25); baseZoom = zoom
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
