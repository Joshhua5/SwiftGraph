import SwiftUI

/// Lays out one example asynchronously and draws the result.
struct GraphExampleView: View {
    let example: GraphExample
    var showsHeader = true

    @State private var snapshot: GraphSnapshot?
    @State private var errorMessage: String?
    @State private var showLabels = true

    init(example: GraphExample, showsHeader: Bool = true) {
        self.example = example; self.showsHeader = showsHeader
    }

    /// Starts with an already computed layout, so static preview snapshots never show the spinner.
    init(example: GraphExample, showsHeader: Bool = true, prerendered result: Result<GraphSnapshot, any Error>) {
        self.init(example: example, showsHeader: showsHeader)
        switch result {
        case .success(let value): _snapshot = State(initialValue: value)
        case .failure(let error): _errorMessage = State(initialValue: String(describing: error))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader { header }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.background)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                if let snapshot {
                    GraphCanvas(snapshot: snapshot, showLabels: showLabels).padding(8)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary).padding()
                } else {
                    ProgressView("Laying out…")
                }
            }
        }
        .padding()
        .task(id: example.id) {
            guard snapshot == nil, errorMessage == nil else { return }
            do { snapshot = try await example.render() } catch { errorMessage = String(describing: error) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(example.title).font(.title2.bold())
                Text(example.summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let snapshot {
                Text("\(snapshot.nodes.count) nodes · \(snapshot.edges.count) edges · \(snapshot.duration.formatted(.units(allowed: [.milliseconds], width: .narrow)))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Toggle("Labels", isOn: $showLabels).toggleStyle(.button).controlSize(.small)
        }
    }
}
