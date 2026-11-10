import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Optional per-node visual overrides for leaf nodes. Any `nil` property falls back to `GraphStyle`.
public struct GraphNodeStyle: Sendable, Equatable {
    public var fill: Color?
    public var stroke: Color?
    public var textColor: Color?
    public var lineWidth: CGFloat?
    public var cornerRadius: CGFloat?
    public var dash: [CGFloat]?
    public var fontWeight: Font.Weight?

    public init(
        fill: Color? = nil,
        stroke: Color? = nil,
        textColor: Color? = nil,
        lineWidth: CGFloat? = nil,
        cornerRadius: CGFloat? = nil,
        dash: [CGFloat]? = nil,
        fontWeight: Font.Weight? = nil
    ) {
        self.fill = fill
        self.stroke = stroke
        self.textColor = textColor
        self.lineWidth = lineWidth
        self.cornerRadius = cornerRadius
        self.dash = dash
        self.fontWeight = fontWeight
    }
}
