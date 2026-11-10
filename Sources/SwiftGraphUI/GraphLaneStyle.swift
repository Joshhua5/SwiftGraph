import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Optional per-lane visual overrides for swimlanes. Any `nil` property falls back to `GraphStyle`.
public struct GraphLaneStyle: Sendable, Equatable {
    public var tint: Color?
    public var fillOpacity: Double?
    public var headerOpacity: Double?
    public var strokeOpacity: Double?
    public var cornerRadius: CGFloat?

    public init(
        tint: Color? = nil,
        fillOpacity: Double? = nil,
        headerOpacity: Double? = nil,
        strokeOpacity: Double? = nil,
        cornerRadius: CGFloat? = nil
    ) {
        self.tint = tint
        self.fillOpacity = fillOpacity
        self.headerOpacity = headerOpacity
        self.strokeOpacity = strokeOpacity
        self.cornerRadius = cornerRadius
    }
}

// MARK: - GraphStyle
