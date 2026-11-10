import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension View {
    /// Sets the `GraphStyle` for any `GraphCanvas` or `GraphView` within this view hierarchy.
    public func graphStyle(_ style: GraphStyle) -> some View {
        environment(\.graphStyle, style)
    }

    /// Provides per-node style overrides for leaf nodes rendered in `GraphCanvas` or `GraphView`.
    public func graphNodeStyle(_ resolver: @escaping @Sendable (GraphSnapshot.Node) -> GraphNodeStyle?) -> some View {
        environment(\.graphNodeStyleResolver, resolver)
    }

    /// Provides per-group style overrides for group container nodes rendered in `GraphCanvas` or `GraphView`.
    public func graphGroupStyle(_ resolver: @escaping @Sendable (GraphSnapshot.Node) -> GraphGroupStyle?) -> some View {
        environment(\.graphGroupStyleResolver, resolver)
    }

    /// Provides per-edge style overrides for edges rendered in `GraphCanvas` or `GraphView`.
    public func graphEdgeStyle(_ resolver: @escaping @Sendable (GraphSnapshot.Edge) -> GraphEdgeStyle?) -> some View {
        environment(\.graphEdgeStyleResolver, resolver)
    }

    /// Provides per-lane style overrides for swimlanes rendered in `GraphCanvas` or `GraphView`.
    public func graphLaneStyle(
        _ resolver: @escaping @Sendable (GraphSnapshot.Lane, Int) -> GraphLaneStyle?
    ) -> some View {
        environment(\.graphLaneStyleResolver, resolver)
    }
}
