import SwiftUI

// One PreviewProvider per example. Unlike `#Preview`, `PreviewProvider` does not route through
// PreviewsMacros, which otherwise triggers a toolchain compiler crash in `isSendableType`.
// Preview indices in this file (0-based):
// 0 Gallery, 1 Hierarchical, 2 Organic, 3 Tree, 4 Radial Tree, 5 Circular, 6 Orthogonal+Channel, 7 BSP, 8 Bundling,
// 9 Framed Groups, 10 Swimlanes, 11 All Presets, 12 Production Topology.

@MainActor
private func preview(_ example: GraphExample) -> some View {
    GraphExampleView(example: example, prerendered: example.renderSynchronously())
        .frame(width: 900, height: 650)
        .previewDisplayName(example.title)
}

struct GalleryPreview: PreviewProvider {
    static var previews: some View {
        GalleryView().frame(width: 1100, height: 740).previewDisplayName("Gallery")
    }
}
struct HierarchicalPreview: PreviewProvider {
    static var previews: some View { preview(.hierarchical) }
}
struct OrganicPreview: PreviewProvider {
    static var previews: some View { preview(.organic) }
}
struct TreePreview: PreviewProvider {
    static var previews: some View { preview(.tree) }
}
struct RadialTreePreview: PreviewProvider {
    static var previews: some View { preview(.radialTree) }
}
struct CircularPreview: PreviewProvider {
    static var previews: some View { preview(.circular) }
}
struct OrthogonalChannelPreview: PreviewProvider {
    static var previews: some View { preview(.orthogonalChannel) }
}
struct BSPRoutingPreview: PreviewProvider {
    static var previews: some View { preview(.bsp) }
}
struct EdgeBundlingPreview: PreviewProvider {
    static var previews: some View { preview(.bundling) }
}
struct FramedGroupsPreview: PreviewProvider {
    static var previews: some View { preview(.groupedArchitecture) }
}
struct SwimlanesPreview: PreviewProvider {
    static var previews: some View { preview(.swimlane) }
}

struct AllPresetsPreview: PreviewProvider {
    static var previews: some View {
        let rendered = GraphExample.renderAllSynchronously(GraphExample.presets)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                ForEach(GraphExample.presets) { example in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(example.title).font(.headline).padding(.horizontal, 12).padding(.top, 8)
                        GraphExampleView(
                            example: example,
                            showsHeader: false,
                            prerendered: rendered[example.id] ?? .failure(CancellationError())
                        )
                        .frame(height: 260)
                    }
                }
            }
            .padding()
        }
        .frame(width: 1100, height: 900)
        .previewDisplayName("All Presets")
    }
}

/// Renders one JSON file from `<repo>/Topologies` (or `<repo>/docs`). Edit the three constants to inspect another file
/// or configuration.
struct ProductionTopologyPreview: PreviewProvider {
    static let fileName = "graph-topology"
    static let layout = TopologyLayout.algorithm(.hierarchical)
    static let routing = TopologyRouting.straight

    static var previews: some View {
        let file = TopologyLibrary.resolve(named: fileName)
        let example = GraphExample.topology(file, layout: layout, routing: routing)
        GraphExampleView(example: example, prerendered: example.renderSynchronously())
            .frame(width: 1100, height: 800)
            .previewDisplayName("Topology: \(fileName)")
    }
}
