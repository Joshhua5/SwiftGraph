import SwiftUI

// One preview per example so each layout can be rendered and inspected on its own.
// PreviewProvider is used rather than #Preview because the package still deploys to macOS 13.
// Index order in this file (for preview tooling): 0 Gallery, 1 Hierarchical, 2 Organic, 3 Tree,
// 4 Radial Tree, 5 Circular, 6 Orthogonal + Channel, 7 BSP Routing, 8 Edge Bundling,
// 9 Framed Groups, 10 Swimlanes, 11 All Presets, 12 Production Topology.

private func preview(_ example: GraphExample) -> some View {
    GraphExampleView(example: example, prerendered: example.renderSynchronously())
        .frame(width: 900, height: 650)
        .previewDisplayName(example.title)
}

struct GalleryPreview: PreviewProvider {
    static var previews: some View { GalleryView().frame(width: 1100, height: 700).previewDisplayName("Gallery") }
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

struct BspRoutingPreview: PreviewProvider {
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

/// All 17 presets in a grid, for side-by-side comparison.
struct AllPresetsPreview: PreviewProvider {
    static var previews: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
            ForEach(GraphExample.presets) { example in
                VStack(alignment: .leading, spacing: 0) {
                    Text(example.title).font(.headline).padding(.horizontal)
                    GraphExampleView(example: example, showsHeader: false, prerendered: example.renderSynchronously())
                        .frame(height: 300)
                }
            }
        }
        .padding(.top)
        .frame(width: 1200, height: 1900)
        .previewDisplayName("All Presets")
    }
}

/// A production graph from `<repo>/Topologies`. Edit the three constants to inspect another file,
/// layout or routing; the pickers in the gallery app offer the same choices interactively.
struct ProductionTopologyPreview: PreviewProvider {
    static let fileName = "graph-topology"
    static let layout = TopologyLayout.algorithm(.organic)
    static let routing = TopologyRouting.bsp

    static var previews: some View {
        let file = TopologyFile(url: TopologyLibrary.directory.appendingPathComponent("\(fileName).json"))
        let example = GraphExample.topology(file, layout: layout, routing: routing)
        GraphExampleView(example: example, prerendered: example.renderSynchronously())
            .frame(width: 1100, height: 800)
            .previewDisplayName("Topology: \(fileName)")
    }
}
