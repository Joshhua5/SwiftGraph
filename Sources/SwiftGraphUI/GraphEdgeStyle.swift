import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Optional per-edge visual overrides. Any `nil` property falls back to `GraphStyle`.
public struct GraphEdgeStyle: Sendable, Equatable {
    public var color: Color?
    public var lineWidth: CGFloat?
    public var cornerRadius: CGFloat?
    public var dash: [CGFloat]?
    public var showsArrowhead: Bool?
    public var showsPortDot: Bool?

    public init(
        color: Color? = nil,
        lineWidth: CGFloat? = nil,
        cornerRadius: CGFloat? = nil,
        dash: [CGFloat]? = nil,
        showsArrowhead: Bool? = nil,
        showsPortDot: Bool? = nil
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.cornerRadius = cornerRadius
        self.dash = dash
        self.showsArrowhead = showsArrowhead
        self.showsPortDot = showsPortDot
    }
}
