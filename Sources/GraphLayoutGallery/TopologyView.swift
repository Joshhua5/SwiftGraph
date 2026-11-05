import SwiftGraph
import SwiftUI

/// A production topology file with pickers for its layout and edge routing.
struct TopologyView: View {
    let file: TopologyFile
    @State private var layout: TopologyLayout
    @State private var routing: TopologyRouting

    init(file: TopologyFile, layout: TopologyLayout = .default, routing: TopologyRouting = .layoutDefault) {
        self.file = file
        _layout = State(initialValue: layout)
        _routing = State(initialValue: routing)
    }

    private var example: GraphExample { .topology(file, layout: layout, routing: routing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Layout", selection: $layout) {
                    Section("Presets") {
                        ForEach(LayoutPatternType.allCases, id: \.self) { Text($0.rawValue).tag(TopologyLayout.preset($0)) }
                    }
                    Section("Algorithms (recursive groups)") {
                        ForEach(TopologyLayout.Algorithm.allCases, id: \.self) { Text($0.rawValue).tag(TopologyLayout.algorithm($0)) }
                    }
                }
                .frame(maxWidth: 320)
                Picker("Routing", selection: $routing) {
                    ForEach(TopologyRouting.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 280)
                Spacer()
            }
            .padding([.horizontal, .top])
            // Fresh identity per configuration so the cached snapshot is discarded and the layout reruns.
            GraphExampleView(example: example).id(example.id)
        }
    }
}
