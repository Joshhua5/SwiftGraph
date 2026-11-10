public protocol LayoutAlgorithm: AsyncLayoutAlgorithm {
    func applyLayout(_ graph: LayoutGraph) throws
}

extension LayoutAlgorithm {
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        try Task.checkCancellation()
        try applyLayout(graph)
    }
}
