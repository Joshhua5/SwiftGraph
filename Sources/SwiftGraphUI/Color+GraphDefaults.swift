import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension Color {
    #if canImport(AppKit)

    /// Default fill color for leaf nodes.
    public static let graphNodeFill = Color(nsColor: .controlBackgroundColor)

    /// Default background color for edge label badges.
    public static let graphLabelBackground = Color(nsColor: .windowBackgroundColor)

    /// Default background color for the graph canvas and group title tabs.
    public static let graphCanvasBackground = Color(nsColor: .textBackgroundColor)
    #else

    /// Default fill color for leaf nodes.
    public static let graphNodeFill = Color(uiColor: .secondarySystemBackground)

    /// Default background color for edge label badges.
    public static let graphLabelBackground = Color(uiColor: .systemBackground)

    /// Default background color for the graph canvas and group title tabs.
    public static let graphCanvasBackground = Color(uiColor: .systemBackground)
    #endif
}

// MARK: - Per-Element Style Overrides
