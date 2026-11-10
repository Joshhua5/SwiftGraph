import Foundation

extension LayoutBuilder {
    /// `nested`, when given, lays out every group except the root. Use it when a core's size parameters
    /// describe the whole drawing (for example a circle radius) and would inflate small nested frames.
    @discardableResult
    func groupedPreset(
        _ core: any LayoutAlgorithm,
        nested: (any LayoutAlgorithm)? = nil,
        routing: PresetRouting
    ) -> Self {
        let groups = RecursiveGroupLayout(core)
        if let nested { groups.groupLayoutSelector = { $0.parent == nil ? core : nested } }
        groups.presetRouting = { routing.apply($0) }
        // Alignment after fitting must not regenerate a preset's final routes.
        groups.optimizeIncomingEdges = false
        return useAlgorithm(groups)
    }

    @discardableResult
    func groupedPreset(
        _ core: any AsyncLayoutAlgorithm,
        nested: (any AsyncLayoutAlgorithm)? = nil,
        routing: PresetRouting,
        backend: LayoutBackend,
        executor: LayoutExecutor
    ) -> Self {
        let groups = RecursiveGroupLayoutOperation(core, backend: backend, executor: executor)
        if let nested { groups.groupLayoutSelector = { $0.parent == nil ? core : nested } }
        groups.presetRouting = { try await routing.apply($0, backend: backend, executor: executor) }
        groups.optimizeIncomingEdges = false
        return useAsyncAlgorithm(groups)
    }
}
