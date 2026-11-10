import CoreGraphics
import Foundation
import SwiftGraph

/// Adopt this protocol on types stored in `LayoutNode.data` to supply custom presentation styling
/// when constructing a `GraphSnapshot`.
public protocol GraphNodeDescriptor {
    var nodeStyle: GraphNodeStyle? { get }
    var groupStyle: GraphGroupStyle? { get }
}

extension GraphNodeDescriptor {
    public var nodeStyle: GraphNodeStyle? { nil }
    public var groupStyle: GraphGroupStyle? { nil }
}
