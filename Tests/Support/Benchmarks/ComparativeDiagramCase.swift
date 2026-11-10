import Foundation
import SwiftGraph

/// A unified diagram case capable of executing identically structured workloads across
/// `.cpu`, `.metal`, and `.automatic` backends while capturing both resulting geometry
/// (`VisualDrawing`) and per-stage execution telemetry (`[LayoutExecutionMetrics]`).
public struct ComparativeDiagramCase {
    public var id: String
    public var family: String
    public var title: String
    public var configuration: [String: String]
    var contracts: VisualContracts
    public var smoke: Bool
    var runBackend: (LayoutBackend, LayoutExecutor) async throws -> (VisualDrawing, [LayoutExecutionMetrics])

    func visualCase(for backend: LayoutBackend, executor: LayoutExecutor) -> VisualCase {
        var config = configuration
        config["backend"] = backend.rawValue
        return VisualCase(
            id: id,
            family: family,
            title: title,
            configuration: config,
            contracts: contracts,
            smoke: smoke,
            metal: backend == .metal
        ) {
            try await runWithPrecisionFallbackIfNeeded(backend: backend, executor: executor).0
        }
    }

    func runWithPrecisionFallbackIfNeeded(
        backend: LayoutBackend,
        executor: LayoutExecutor
    ) async throws -> (VisualDrawing, [LayoutExecutionMetrics], Bool) {
        do {
            let (drawing, metrics) = try await runBackend(backend, executor)
            return (drawing, metrics, false)
        } catch LayoutExecutionError.precisionLimit where backend == .metal {
            var relaxedOptions = await executor.options
            relaxedOptions.maximumCoordinateError = max(relaxedOptions.maximumCoordinateError, 1.0)
            let relaxedExecutor = LayoutExecutor(options: relaxedOptions)
            var (drawing, metrics) = try await runBackend(.metal, relaxedExecutor)
            drawing.notes.append(
                "Default Metal maximumCoordinateError (0.01) rejected this coordinate span; executed with relaxed tolerance (1.0) for comparative analysis."
            )
            return (drawing, metrics, true)
        }
    }
}
