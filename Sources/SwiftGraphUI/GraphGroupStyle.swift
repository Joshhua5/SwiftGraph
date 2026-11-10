import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Optional per-group visual overrides for group container nodes. Any `nil` property falls back to `GraphStyle`.
public struct GraphGroupStyle: Sendable, Equatable {
    public var tint: Color?
    public var fillOpacity: Double?
    public var headerOpacity: Double?
    public var strokeOpacity: Double?
    public var lineWidth: CGFloat?
    public var cornerRadius: CGFloat?
    public var dash: [CGFloat]?
    public var fontWeight: Font.Weight?

    public init(
        tint: Color? = nil,
        fillOpacity: Double? = nil,
        headerOpacity: Double? = nil,
        strokeOpacity: Double? = nil,
        lineWidth: CGFloat? = nil,
        cornerRadius: CGFloat? = nil,
        dash: [CGFloat]? = nil,
        fontWeight: Font.Weight? = nil
    ) {
        self.tint = tint
        self.fillOpacity = fillOpacity
        self.headerOpacity = headerOpacity
        self.strokeOpacity = strokeOpacity
        self.lineWidth = lineWidth
        self.cornerRadius = cornerRadius
        self.dash = dash
        self.fontWeight = fontWeight
    }
}
