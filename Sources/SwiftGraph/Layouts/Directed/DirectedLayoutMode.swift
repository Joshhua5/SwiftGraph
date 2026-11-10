import Foundation

/// The quality-oriented directed pipeline is separate from the parity-preserving routers.
public enum DirectedLayoutMode: Hashable, Sendable { case fresh, incremental, routesOnly }
