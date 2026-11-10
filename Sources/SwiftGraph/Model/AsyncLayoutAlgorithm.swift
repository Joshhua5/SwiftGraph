public protocol AsyncLayoutAlgorithm {
    func applyLayoutAsync(_ graph: LayoutGraph) async throws
}
