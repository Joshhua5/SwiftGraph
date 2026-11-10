import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private struct GraphStyleKey: EnvironmentKey {
    static let defaultValue = GraphStyle.default
}

private struct GraphNodeStyleResolverKey: EnvironmentKey {
    static let defaultValue: (@Sendable (GraphSnapshot.Node) -> GraphNodeStyle?)? = nil
}

private struct GraphGroupStyleResolverKey: EnvironmentKey {
    static let defaultValue: (@Sendable (GraphSnapshot.Node) -> GraphGroupStyle?)? = nil
}

private struct GraphEdgeStyleResolverKey: EnvironmentKey {
    static let defaultValue: (@Sendable (GraphSnapshot.Edge) -> GraphEdgeStyle?)? = nil
}

private struct GraphLaneStyleResolverKey: EnvironmentKey {
    static let defaultValue: (@Sendable (GraphSnapshot.Lane, Int) -> GraphLaneStyle?)? = nil
}

extension EnvironmentValues {
    /// The current `GraphStyle` used by `GraphCanvas` and `GraphView`.
    public var graphStyle: GraphStyle {
        get { self[GraphStyleKey.self] }
        set { self[GraphStyleKey.self] = newValue }
    }

    var graphNodeStyleResolver: (@Sendable (GraphSnapshot.Node) -> GraphNodeStyle?)? {
        get { self[GraphNodeStyleResolverKey.self] }
        set { self[GraphNodeStyleResolverKey.self] = newValue }
    }

    var graphGroupStyleResolver: (@Sendable (GraphSnapshot.Node) -> GraphGroupStyle?)? {
        get { self[GraphGroupStyleResolverKey.self] }
        set { self[GraphGroupStyleResolverKey.self] = newValue }
    }

    var graphEdgeStyleResolver: (@Sendable (GraphSnapshot.Edge) -> GraphEdgeStyle?)? {
        get { self[GraphEdgeStyleResolverKey.self] }
        set { self[GraphEdgeStyleResolverKey.self] = newValue }
    }

    var graphLaneStyleResolver: (@Sendable (GraphSnapshot.Lane, Int) -> GraphLaneStyle?)? {
        get { self[GraphLaneStyleResolverKey.self] }
        set { self[GraphLaneStyleResolverKey.self] = newValue }
    }
}
