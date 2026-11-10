import Foundation

/// Swift payloads can opt into labeling without reflection or coupling to a UI framework.
public protocol GraphLabelData { var label: String { get } }

func defaultLabelProvider(_ edge: LayoutEdge) -> String? {
    if let value = edge.data as? any GraphLabelData { return value.label }
    if let value = edge.data as? String { return value }
    if let value = edge.data as? [String: String] { return value["Label"] ?? value["label"] }
    return nil
}

/// A label's size: what the caller measured (the provider, else a size already set on `labelBounds`), else a character
/// estimate.
func labelSize(_ edge: LayoutEdge, text: String?, provider: (LayoutEdge, String) -> Size?) -> Size {
    if let text, let measured = provider(edge, text), measured.width > 0, measured.height > 0 { return measured }
    if edge.labelBounds.width > 0 && edge.labelBounds.height > 0 { return edge.labelBounds.size }
    return Size(width: Float((text?.count ?? 0) * 8 + 10), height: 20)
}
