import Foundation

struct OrganicResult: Sendable {
    var centers: [Point]
    var fixed: [Bool]
    var metrics: LayoutExecutionMetrics
    var diagnostics: OrganicLayoutDiagnostics? = nil
}
