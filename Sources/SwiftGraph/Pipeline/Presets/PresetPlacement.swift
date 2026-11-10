import Foundation

/// Small placement-only compositions used on measured container proxies.
final class PresetPlacement: LayoutAlgorithm {
    private let operation: (LayoutGraph) throws -> Void

    init(_ operation: @escaping (LayoutGraph) throws -> Void) { self.operation = operation }

    func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        try operation(graph)
    }
}
