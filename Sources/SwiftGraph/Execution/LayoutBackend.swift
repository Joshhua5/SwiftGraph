import Foundation

/// Selects CPU, Metal, or per-operation automatic backend selection.
public enum LayoutBackend: String, Sendable { case cpu, metal, automatic }
