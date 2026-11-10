import SwiftGraph
import SwiftUI

/// Hosts an asynchronous `SwiftGraph` layout pipeline, reporting progress while laying out off the main actor
/// and rendering the resulting `GraphSnapshot` in an `InteractiveGraphCanvas`.
public struct GraphView: View {
    private let id: AnyHashable
    private let backend: LayoutBackend
    private let makeGraph: @Sendable () throws -> LayoutGraph
    private let configure: @Sendable (LayoutBuilder, LayoutBackend) -> Void
    private var externalViewport: Binding<GraphViewport>?
    private var showLabels: Bool?
    private var cornerRadius: CGFloat
    private var showsBorder: Bool
    private var onSnapshotChange: (@MainActor (GraphSnapshot) -> Void)?

    @Environment(\.graphStyle) private var style
    @State private var ownedViewport = GraphViewport()
    @State private var snapshot: GraphSnapshot?
    @State private var errorMessage: String?
    @State private var renderedKey: AnyHashable?
    @State private var progress: LayoutProgress?
    @State private var isRendering = false
    @State private var renderToken = UUID()

    private struct RenderKey: Hashable {
        var id: AnyHashable
        var backend: LayoutBackend
    }

    private var viewportBinding: Binding<GraphViewport> {
        externalViewport ?? $ownedViewport
    }

    /// Creates a `GraphView` that builds and lays out a `LayoutGraph` asynchronously whenever `id` or `backend`
    /// changes.
    public init<ID: Hashable>(
        id: ID = 0,
        backend: LayoutBackend = .cpu,
        viewport: Binding<GraphViewport>? = nil,
        showLabels: Bool? = nil,
        cornerRadius: CGFloat = 10,
        showsBorder: Bool = true,
        prerendered: Result<GraphSnapshot, any Error>? = nil,
        onSnapshotChange: (@MainActor (GraphSnapshot) -> Void)? = nil,
        makeGraph: @escaping @Sendable () throws -> LayoutGraph,
        configure: @escaping @Sendable (LayoutBuilder, LayoutBackend) -> Void
    ) {
        let erasedID = AnyHashable(id)
        self.id = erasedID
        self.backend = backend
        self.externalViewport = viewport
        self.showLabels = showLabels
        self.cornerRadius = cornerRadius
        self.showsBorder = showsBorder
        self.onSnapshotChange = onSnapshotChange
        self.makeGraph = makeGraph
        self.configure = configure

        if let prerendered {
            _renderedKey = State(initialValue: AnyHashable(RenderKey(id: erasedID, backend: backend)))
            switch prerendered {
            case .success(let value):
                _snapshot = State(initialValue: value)
            case .failure(let error):
                _errorMessage = State(initialValue: String(describing: error))
            }
        }
    }

    /// Creates a `GraphView` that displays an already computed `GraphSnapshot`.
    public init(
        snapshot: GraphSnapshot,
        viewport: Binding<GraphViewport>? = nil,
        showLabels: Bool? = nil,
        cornerRadius: CGFloat = 10,
        showsBorder: Bool = true
    ) {
        self.init(
            id: 0,
            backend: .cpu,
            viewport: viewport,
            showLabels: showLabels,
            cornerRadius: cornerRadius,
            showsBorder: showsBorder,
            prerendered: .success(snapshot),
            makeGraph: { LayoutGraph() },
            configure: { _, _ in }
        )
    }

    public var body: some View {
        let currentKey = AnyHashable(RenderKey(id: id, backend: backend))
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(style.canvasBackground)
                .overlay {
                    if showsBorder {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(.separator)
                    }
                }

            if let snapshot {
                InteractiveGraphCanvas(
                    snapshot: snapshot,
                    viewport: viewportBinding,
                    showLabels: showLabels
                )
                .padding(8)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                // Re-rendering for another backend or configuration keeps the previous drawing until the new one is
                // ready.
                .overlay(alignment: .bottom) {
                    if isRendering {
                        progressIndicator
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(12)
                    }
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                progressIndicator
            }
        }
        .task(id: currentKey) {
            guard renderedKey != currentKey || (snapshot == nil && errorMessage == nil) else {
                if let snapshot {
                    onSnapshotChange?(snapshot)
                }
                return
            }
            errorMessage = nil
            let token = UUID()
            renderToken = token
            progress = nil
            isRendering = true
            defer { if renderToken == token { isRendering = false } }
            do {
                let rendered = try await GraphSnapshot.render(
                    backend: backend,
                    makeGraph: makeGraph,
                    configure: configure
                ) { latestProgress in
                    progress = latestProgress
                }
                snapshot = rendered
                renderedKey = currentKey
                onSnapshotChange?(rendered)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = String(describing: error)
                renderedKey = currentKey
            }
        }
    }

    /// Overall completion and the current stage path, e.g. "Organic › Candidate 3/12 › Force simulation".
    private var progressIndicator: some View {
        VStack(spacing: 6) {
            ProgressView(value: progress?.fraction ?? 0)
                .frame(maxWidth: 280)
            Text(progress.flatMap { $0.stages.isEmpty ? nil : $0.stages.joined(separator: " › ") } ?? "Laying out…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280)
        }
    }
}
