import CoreGraphics
import Foundation
import SwiftGraph

/// Adopt this protocol on types stored in `LayoutEdge.data` to supply edge labels, bidirectionality,
/// or per-edge styling when constructing a `GraphSnapshot`.
public protocol GraphEdgeDescriptor {
    var edgeLabel: String? { get }
    var isBidirectional: Bool { get }
    var edgeStyle: GraphEdgeStyle? { get }
}

extension GraphEdgeDescriptor {
    public var edgeLabel: String? { nil }
    public var isBidirectional: Bool { false }
    public var edgeStyle: GraphEdgeStyle? { nil }
}

// MARK: - GraphSnapshot
