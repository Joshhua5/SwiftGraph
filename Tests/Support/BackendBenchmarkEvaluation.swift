import Foundation
import SwiftGraph

public enum ParityClassification: String, Codable, Sendable {
    case exact
    case floatEquivalent
    case heuristicDivergent
    case qualityRegression
}

public struct OutputComparisonSummary: Codable, Sendable {
    public var nodeCount: Int
    public var edgeCount: Int
    public var groupCount: Int
    public var changedNodeCount: Int
    public var changedEdgeCount: Int
    public var edgePointCountMismatches: Int
    public var rawNodeCenterRMS: Double
    public var rawNodeCenterMax: Double
    public var maxNodeBoundsDelta: Double
    public var centroidAlignedNodeRMS: Double
    public var centroidAlignedNodeMax: Double
    public var maxEdgePointDeviation: Double
    public var meanEdgePointDeviation: Double
    public var cpuContractFailures: [String]
    public var metalContractFailures: [String]
    public var cpuMetrics: [String: Double]
    public var metalMetrics: [String: Double]
    public var metricDeltas: [String: Double]
    public var qualityFlags: [String]
    public var parityClassification: ParityClassification
}

public struct TimingComparisonSummary: Codable, Sendable {
    public var trials: Int
    public var cpuColdMs: Double
    public var cpuWarmMedianMs: Double
    public var cpuWarmMinMs: Double
    public var cpuWarmMaxMs: Double
    public var metalColdMs: Double
    public var metalWarmMedianMs: Double
    public var metalWarmMinMs: Double
    public var metalWarmMaxMs: Double
    public var metalComputeMedianMs: Double
    public var metalGpuKernelMedianMs: Double?
    public var metalCpuPrepMedianMs: Double
    public var metalOverheadMedianMs: Double
    public var gpuUtilizationFraction: Double
    public var speedupVsCPU: Double
    public var kernelSpeedupVsCPU: Double?
    public var submittedBatches: Int
    public var completedBatches: Int
    public var pipelineBuilds: Int
    public var bufferAllocations: Int
    public var bufferReuses: Int
    public var automaticChoseBackend: String
    public var automaticFallbackReason: String?
    public var precisionLimitExceededDefault: Bool
    public var metalStages: [String]
    public var cpuStagesInMetalMode: [String]
}

public enum BottleneckKind: String, Codable, CaseIterable, Sendable {
    case noMetalStagesSubmitted
    case lowGpuUtilization
    case highMicroDispatchOverhead
    case metalSlowerThanCPU
    case unacceleratedPipelineStage
    case precisionLimitFallback
    case thresholdFallback
    case qualityRegression
}

public struct BottleneckFinding: Codable, Equatable, Sendable {
    public var kind: BottleneckKind
    public var severity: String
    public var summary: String
    public var evidence: String

    public init(kind: BottleneckKind, severity: String, summary: String, evidence: String) {
        self.kind = kind
        self.severity = severity
        self.summary = summary
        self.evidence = evidence
    }
}

public struct ComparativeCaseResult: Codable, Sendable {
    public var id: String
    public var family: String
    public var title: String
    public var configuration: [String: String]
    public var output: OutputComparisonSummary
    public var timing: TimingComparisonSummary
    public var bottlenecks: [BottleneckFinding]
    public var notes: [String]
}

public struct FamilyAggregateSummary: Codable, Sendable {
    public var family: String
    public var caseCount: Int
    public var exactParityCount: Int
    public var floatEquivalentCount: Int
    public var heuristicDivergentCount: Int
    public var qualityRegressionCount: Int
    public var cpuTotalWarmMs: Double
    public var metalTotalWarmMs: Double
    public var gpuKernelTotalMs: Double
    public var medianSpeedup: Double
    public var meanGpuUtilization: Double
    public var fasterOnMetalCount: Int
    public var slowerOnMetalCount: Int
}

public struct BackendComparativeReport: Codable, Sendable {
    public var version: Int = 1
    public var generatedAt: String
    public var deviceName: String
    public var environment: [String: String]
    public var totalCases: Int
    public var trialsPerCase: Int
    public var families: [FamilyAggregateSummary]
    public var bottleneckCounts: [String: Int]
    public var cases: [ComparativeCaseResult]
}

public enum BackendBenchmarkEvaluation {
    public static func evaluate(
        cases: [ComparativeDiagramCase],
        trials: Int = 3,
        outputDirectory: URL? = nil,
        renderImages: Bool = false
    ) async throws -> BackendComparativeReport {
        let warmTrials = max(1, trials)
        let sharedExecutor = LayoutExecutor()
        if let outputDirectory {
            try FileManager.default.createDirectory(
                at: outputDirectory.appendingPathComponent("cases"),
                withIntermediateDirectories: true
            )
        }

        var results: [ComparativeCaseResult] = []
        var detectedDeviceName: String?

        for item in cases {
            let caseResult = try await evaluateCase(
                item,
                warmTrials: warmTrials,
                sharedExecutor: sharedExecutor,
                outputDirectory: outputDirectory,
                renderImages: renderImages,
                detectedDeviceName: &detectedDeviceName
            )
            results.append(caseResult)
        }

        let familyOrder = BackendComparativeCatalogue.familyOrder
        let grouped = Dictionary(grouping: results, by: \.family)
        let sortedFamilies = grouped.keys.sorted { a, b in
            let ia = familyOrder.firstIndex(of: a) ?? Int.max
            let ib = familyOrder.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }

        let familySummaries: [FamilyAggregateSummary] = sortedFamilies.map { family in
            let items = grouped[family] ?? []
            let speedups = items.map(\.timing.speedupVsCPU).sorted()
            let medianSpeedup = median(speedups)
            let meanUtil = items.isEmpty ? 0 : items.map(\.timing.gpuUtilizationFraction).reduce(0, +) / Double(items.count)
            return FamilyAggregateSummary(
                family: family,
                caseCount: items.count,
                exactParityCount: items.filter { $0.output.parityClassification == .exact }.count,
                floatEquivalentCount: items.filter { $0.output.parityClassification == .floatEquivalent }.count,
                heuristicDivergentCount: items.filter { $0.output.parityClassification == .heuristicDivergent }.count,
                qualityRegressionCount: items.filter { $0.output.parityClassification == .qualityRegression }.count,
                cpuTotalWarmMs: items.map(\.timing.cpuWarmMedianMs).reduce(0, +),
                metalTotalWarmMs: items.map(\.timing.metalWarmMedianMs).reduce(0, +),
                gpuKernelTotalMs: items.compactMap(\.timing.metalGpuKernelMedianMs).reduce(0, +),
                medianSpeedup: medianSpeedup,
                meanGpuUtilization: meanUtil,
                fasterOnMetalCount: items.filter { $0.timing.speedupVsCPU >= 1.0 }.count,
                slowerOnMetalCount: items.filter { $0.timing.speedupVsCPU < 1.0 }.count
            )
        }

        var bottleneckCounts: [String: Int] = [:]
        for kind in BottleneckKind.allCases {
            bottleneckCounts[kind.rawValue] = results.filter { r in r.bottlenecks.contains { $0.kind == kind } }.count
        }

        let formatter = ISO8601DateFormatter()
        let report = BackendComparativeReport(
            generatedAt: formatter.string(from: Date()),
            deviceName: detectedDeviceName ?? (LayoutExecutor.isMetalAvailable ? "Apple Metal GPU" : "Metal Unavailable"),
            environment: VisualStorage.environment(),
            totalCases: results.count,
            trialsPerCase: warmTrials,
            families: familySummaries,
            bottleneckCounts: bottleneckCounts,
            cases: results
        )

        if let outputDirectory {
            try writeReport(report, to: outputDirectory, renderImages: renderImages)
        }

        return report
    }

    private static func evaluateCase(
        _ item: ComparativeDiagramCase,
        warmTrials: Int,
        sharedExecutor: LayoutExecutor,
        outputDirectory: URL?,
        renderImages: Bool,
        detectedDeviceName: inout String?
    ) async throws -> ComparativeCaseResult {
        // 1. CPU Cold + Warm runs
        let cpuColdStart = ContinuousClock.now
        var (cpuDrawing, _, _) = try await item.runWithPrecisionFallbackIfNeeded(backend: .cpu, executor: sharedExecutor)
        let cpuColdMs = durationMs(cpuColdStart.duration(to: .now))

        var cpuWarmSamples: [Double] = []
        for _ in 0..<warmTrials {
            let t0 = ContinuousClock.now
            let (d, _, _) = try await item.runWithPrecisionFallbackIfNeeded(backend: .cpu, executor: sharedExecutor)
            cpuWarmSamples.append(durationMs(t0.duration(to: .now)))
            cpuDrawing = d
        }

        // 2. Metal Cold run on a fresh executor (measures pipeline compilation + cold buffer setup)
        let coldMetalExecutor = LayoutExecutor()
        let metalColdStart = ContinuousClock.now
        let (_, coldMetalMetrics, coldExceededPrecision) = try await item.runWithPrecisionFallbackIfNeeded(
            backend: .metal,
            executor: coldMetalExecutor
        )
        let metalColdMs = durationMs(metalColdStart.duration(to: .now))
        let coldStats = await coldMetalExecutor.statistics()
        if detectedDeviceName == nil {
            detectedDeviceName = coldMetalMetrics.compactMap(\.deviceName).first
        }

        // 3. Metal Warm runs on sharedExecutor
        var metalWarmSamples: [Double] = []
        var metalComputeSamples: [Double] = []
        var metalGpuSamples: [Double] = []
        var metalPrepSamples: [Double] = []
        var lastMetalDrawing: VisualDrawing?
        var lastMetalMetrics: [LayoutExecutionMetrics] = []
        var precisionExceeded = coldExceededPrecision
        var warmSubmittedDelta = 0
        var warmCompletedDelta = 0
        var warmAllocDelta = 0
        var warmReuseDelta = 0

        for _ in 0..<warmTrials {
            let beforeStats = await sharedExecutor.statistics()
            let t0 = ContinuousClock.now
            let (d, m, exceeded) = try await item.runWithPrecisionFallbackIfNeeded(backend: .metal, executor: sharedExecutor)
            let elapsedMs = durationMs(t0.duration(to: .now))
            let afterStats = await sharedExecutor.statistics()

            metalWarmSamples.append(elapsedMs)
            let computeMs = m.map(\.computeSeconds).reduce(0, +) * 1_000.0
            metalComputeSamples.append(computeMs > 0 ? computeMs : elapsedMs)
            let gpuSec = m.compactMap(\.gpuSeconds).reduce(0, +)
            if m.contains(where: { $0.gpuSeconds != nil }) {
                metalGpuSamples.append(gpuSec * 1_000.0)
            }
            let prepMs = m.map { record in
                record.cpuPreparationSeconds + (record.qualityPhases.map { $0.preparationSeconds + $0.evaluationSeconds } ?? 0)
            }.reduce(0, +) * 1_000.0
            metalPrepSamples.append(prepMs)

            lastMetalDrawing = d
            lastMetalMetrics = m
            precisionExceeded = precisionExceeded || exceeded
            warmSubmittedDelta = max(0, afterStats.submittedBatches - beforeStats.submittedBatches)
            warmCompletedDelta = max(0, afterStats.completedBatches - beforeStats.completedBatches)
            warmAllocDelta = max(0, afterStats.bufferAllocations - beforeStats.bufferAllocations)
            warmReuseDelta = max(0, afterStats.bufferReuses - beforeStats.bufferReuses)
            if detectedDeviceName == nil {
                detectedDeviceName = m.compactMap(\.deviceName).first
            }
        }

        // If precision fallback used a temporary executor inside runWithPrecisionFallbackIfNeeded,
        // estimate batch count from coldStats or stage records when sharedExecutor delta is 0.
        let effectiveSubmittedBatches = warmSubmittedDelta > 0
            ? warmSubmittedDelta
            : (coldStats.submittedBatches > 0 ? coldStats.submittedBatches : lastMetalMetrics.filter { !$0.metalStages.isEmpty }.count)
        let effectiveCompletedBatches = warmCompletedDelta > 0
            ? warmCompletedDelta
            : (coldStats.completedBatches > 0 ? coldStats.completedBatches : effectiveSubmittedBatches)

        // 4. Automatic backend check (1 pass to see what `.automatic` selects and why)
        let (_, autoMetrics, _) = try await item.runWithPrecisionFallbackIfNeeded(backend: .automatic, executor: sharedExecutor)
        let autoBackend: String
        if autoMetrics.contains(where: { $0.backend == .metal }) {
            autoBackend = LayoutBackend.metal.rawValue
        } else {
            autoBackend = LayoutBackend.cpu.rawValue
        }
        let autoFallbackReason = autoMetrics.compactMap { $0.fallbackReason?.rawValue }.first

        // 5. Output & Quality Comparison
        let metalDrawing = lastMetalDrawing!
        let cpuCase = item.visualCase(for: .cpu, executor: sharedExecutor)
        let metalCase = item.visualCase(for: .metal, executor: sharedExecutor)
        var cpuSnapshot = VisualSnapshot(case: cpuCase, drawing: cpuDrawing)
        var metalSnapshot = VisualSnapshot(case: metalCase, drawing: metalDrawing)
        let cpuVisualMetrics = VisualGeometry.measure(cpuSnapshot)
        let metalVisualMetrics = VisualGeometry.measure(metalSnapshot)
        cpuSnapshot.measuredMetrics = cpuVisualMetrics.values
        metalSnapshot.measuredMetrics = metalVisualMetrics.values

        let outputSummary = compareOutputs(
            cpuSnapshot: cpuSnapshot,
            metalSnapshot: metalSnapshot,
            cpuVisualMetrics: cpuVisualMetrics,
            metalVisualMetrics: metalVisualMetrics,
            cpuAdditionalFailures: cpuDrawing.additionalFailures,
            metalAdditionalFailures: metalDrawing.additionalFailures
        )

        // 6. Timing Summary
        let cpuMedian = median(cpuWarmSamples)
        let metalMedian = median(metalWarmSamples)
        let computeMedian = median(metalComputeSamples)
        let gpuKernelMedian = metalGpuSamples.isEmpty ? nil : median(metalGpuSamples)
        let prepMedian = median(metalPrepSamples)
        let gpuMs = gpuKernelMedian ?? 0
        let overheadMs = max(0, metalMedian - gpuMs - prepMedian)
        let gpuUtil = metalMedian > 0 ? min(1.0, gpuMs / metalMedian) : 0
        let speedup = cpuMedian / max(1e-6, metalMedian)
        let kernelSpeedup = gpuKernelMedian.map { $0 > 0 ? cpuMedian / max(1e-6, $0) : 0 }

        let metalStages = uniqueOrdered(lastMetalMetrics.flatMap(\.metalStages))
        let extraCPUStages = precisionExceeded ? ["default-precision-preflight-exceeded"] : []
        let cpuStagesInMetal = uniqueOrdered(extraCPUStages + lastMetalMetrics.flatMap(\.cpuStages))

        let timingSummary = TimingComparisonSummary(
            trials: warmTrials,
            cpuColdMs: cpuColdMs,
            cpuWarmMedianMs: cpuMedian,
            cpuWarmMinMs: cpuWarmSamples.min() ?? cpuMedian,
            cpuWarmMaxMs: cpuWarmSamples.max() ?? cpuMedian,
            metalColdMs: metalColdMs,
            metalWarmMedianMs: metalMedian,
            metalWarmMinMs: metalWarmSamples.min() ?? metalMedian,
            metalWarmMaxMs: metalWarmSamples.max() ?? metalMedian,
            metalComputeMedianMs: computeMedian,
            metalGpuKernelMedianMs: gpuKernelMedian,
            metalCpuPrepMedianMs: prepMedian,
            metalOverheadMedianMs: overheadMs,
            gpuUtilizationFraction: gpuUtil,
            speedupVsCPU: speedup,
            kernelSpeedupVsCPU: kernelSpeedup,
            submittedBatches: effectiveSubmittedBatches,
            completedBatches: effectiveCompletedBatches,
            pipelineBuilds: coldStats.pipelineBuilds,
            bufferAllocations: max(coldStats.bufferAllocations, warmAllocDelta),
            bufferReuses: warmReuseDelta,
            automaticChoseBackend: autoBackend,
            automaticFallbackReason: autoFallbackReason,
            precisionLimitExceededDefault: precisionExceeded,
            metalStages: metalStages,
            cpuStagesInMetalMode: cpuStagesInMetal
        )

        let bottlenecks = classifyBottlenecks(
            item: item,
            output: outputSummary,
            timing: timingSummary
        )

        if let outputDirectory {
            let caseDir = try VisualStorage.caseDirectory(outputDirectory, item.id)
            try VisualStorage.writeJSON(cpuSnapshot, caseDir.appendingPathComponent("cpu.geometry.json"))
            try VisualStorage.writeJSON(metalSnapshot, caseDir.appendingPathComponent("metal.geometry.json"))
            if renderImages {
                let cpuScene = VisualScene(snapshot: cpuSnapshot)
                let metalScene = VisualScene(snapshot: metalSnapshot)
                let overlayScene = VisualScene.overlay(cpuSnapshot, metalSnapshot)
                try VisualRenderer.write(cpuScene, to: caseDir.appendingPathComponent("cpu"))
                try VisualRenderer.write(metalScene, to: caseDir.appendingPathComponent("metal"))
                try VisualRenderer.write(overlayScene, to: caseDir.appendingPathComponent("overlay"))
            }
        }

        let notes = uniqueOrdered(cpuDrawing.notes + metalDrawing.notes)
        return ComparativeCaseResult(
            id: item.id,
            family: item.family,
            title: item.title,
            configuration: item.configuration,
            output: outputSummary,
            timing: timingSummary,
            bottlenecks: bottlenecks,
            notes: notes
        )
    }

    // MARK: - Output & Geometry Comparison

    static func compareOutputs(
        cpuSnapshot: VisualSnapshot,
        metalSnapshot: VisualSnapshot,
        cpuVisualMetrics: VisualMetrics,
        metalVisualMetrics: VisualMetrics,
        cpuAdditionalFailures: [VisualFinding] = [],
        metalAdditionalFailures: [VisualFinding] = []
    ) -> OutputComparisonSummary {
        let diff = VisualComparison.compare(cpuSnapshot, metalSnapshot)
        let cpuNodes = Dictionary(uniqueKeysWithValues: cpuSnapshot.nodes.map { ($0.id, $0) })
        let metalNodes = Dictionary(uniqueKeysWithValues: metalSnapshot.nodes.map { ($0.id, $0) })
        let commonNodeIDs = cpuSnapshot.nodes.map(\.id).filter { metalNodes[$0] != nil }

        var rawSquaredSum = 0.0
        var rawMax = 0.0
        var maxBoundsDelta = 0.0
        var cpuCentroid = Point.zero
        var metalCentroid = Point.zero

        for id in commonNodeIDs {
            let a = cpuNodes[id]!.bounds
            let b = metalNodes[id]!.bounds
            let d = Double((a.center - b.center).length)
            rawSquaredSum += d * d
            rawMax = max(rawMax, d)
            let bDelta = Double(max(abs(a.x - b.x), abs(a.y - b.y), abs(a.width - b.width), abs(a.height - b.height)))
            maxBoundsDelta = max(maxBoundsDelta, bDelta)
            cpuCentroid = cpuCentroid + a.center
            metalCentroid = metalCentroid + b.center
        }

        let nCount = Double(max(1, commonNodeIDs.count))
        let rawRMS = sqrt(rawSquaredSum / nCount)
        cpuCentroid = cpuCentroid / Float(nCount)
        metalCentroid = metalCentroid / Float(nCount)

        var alignedSquaredSum = 0.0
        var alignedMax = 0.0
        for id in commonNodeIDs {
            let aRel = cpuNodes[id]!.bounds.center - cpuCentroid
            let bRel = metalNodes[id]!.bounds.center - metalCentroid
            let d = Double((aRel - bRel).length)
            alignedSquaredSum += d * d
            alignedMax = max(alignedMax, d)
        }
        let alignedRMS = sqrt(alignedSquaredSum / nCount)

        // Edge path deviation
        let cpuEdges = Dictionary(uniqueKeysWithValues: cpuSnapshot.edges.map { ($0.id, $0) })
        let metalEdges = Dictionary(uniqueKeysWithValues: metalSnapshot.edges.map { ($0.id, $0) })
        let commonEdgeIDs = cpuSnapshot.edges.map(\.id).filter { metalEdges[$0] != nil }

        var pointCountMismatches = 0
        var maxEdgeDev = 0.0
        var totalEdgeDev = 0.0
        var totalComparedPoints = 0

        for id in commonEdgeIDs {
            let pa = cpuEdges[id]!.path
            let pb = metalEdges[id]!.path
            if pa.count != pb.count {
                pointCountMismatches += 1
            }
            if !pa.isEmpty && !pb.isEmpty {
                if pa.count == pb.count {
                    for (p, q) in zip(pa, pb) {
                        let d = Double((p - q).length)
                        maxEdgeDev = max(maxEdgeDev, d)
                        totalEdgeDev += d
                        totalComparedPoints += 1
                    }
                } else {
                    // Compare endpoints + resampled midpoint when bend count differs
                    let startDev = Double((pa.first! - pb.first!).length)
                    let endDev = Double((pa.last! - pb.last!).length)
                    let midA = pa[pa.count / 2]
                    let midB = pb[pb.count / 2]
                    let midDev = Double((midA - midB).length)
                    maxEdgeDev = max(maxEdgeDev, startDev, endDev, midDev)
                    totalEdgeDev += startDev + endDev + midDev
                    totalComparedPoints += 3
                }
            }
        }
        let meanEdgeDev = totalComparedPoints > 0 ? totalEdgeDev / Double(totalComparedPoints) : 0.0

        let cpuFailKinds = (cpuVisualMetrics.failures + cpuAdditionalFailures).map(\.kind)
        let metalFailKinds = (metalVisualMetrics.failures + metalAdditionalFailures).map(\.kind)
        let newMetalFailures = Set(metalFailKinds).subtracting(cpuFailKinds)

        let newOverlaps = (metalVisualMetrics.values["nodeOverlaps"] ?? 0) > (cpuVisualMetrics.values["nodeOverlaps"] ?? 0) + 1e-6
        let newObstacleHits = (metalVisualMetrics.values["edgeNodeIntersections"] ?? 0) > (cpuVisualMetrics.values["edgeNodeIntersections"] ?? 0) + 1e-6

        let classification: ParityClassification
        if !newMetalFailures.isEmpty || (metalSnapshot.contracts.noNodeOverlaps && newOverlaps) || (metalSnapshot.contracts.noObstacleIntersections && newObstacleHits) {
            classification = .qualityRegression
        } else if diff.changedNodes.isEmpty && diff.changedEdges.isEmpty {
            classification = .exact
        } else if maxBoundsDelta <= 0.05 && maxEdgeDev <= 0.05 && pointCountMismatches == 0 {
            classification = .floatEquivalent
        } else {
            classification = .heuristicDivergent
        }

        return OutputComparisonSummary(
            nodeCount: cpuSnapshot.nodes.filter { !$0.group }.count,
            edgeCount: cpuSnapshot.edges.count,
            groupCount: cpuSnapshot.nodes.filter(\.group).count,
            changedNodeCount: diff.changedNodes.count,
            changedEdgeCount: diff.changedEdges.count,
            edgePointCountMismatches: pointCountMismatches,
            rawNodeCenterRMS: rawRMS,
            rawNodeCenterMax: rawMax,
            maxNodeBoundsDelta: maxBoundsDelta,
            centroidAlignedNodeRMS: alignedRMS,
            centroidAlignedNodeMax: alignedMax,
            maxEdgePointDeviation: maxEdgeDev,
            meanEdgePointDeviation: meanEdgeDev,
            cpuContractFailures: cpuFailKinds,
            metalContractFailures: metalFailKinds,
            cpuMetrics: cpuVisualMetrics.values,
            metalMetrics: metalVisualMetrics.values,
            metricDeltas: diff.metricDeltas,
            qualityFlags: diff.qualityFlags,
            parityClassification: classification
        )
    }

    // MARK: - Automated Bottleneck & Metal Underutilization Classifier

    public static func classifyBottlenecks(
        item: ComparativeDiagramCase,
        output: OutputComparisonSummary,
        timing: TimingComparisonSummary
    ) -> [BottleneckFinding] {
        var findings: [BottleneckFinding] = []

        if output.parityClassification == .qualityRegression {
            findings.append(BottleneckFinding(
                kind: .qualityRegression,
                severity: "high",
                summary: "Metal output introduced contract or visual quality regression vs CPU",
                evidence: "Metal failures: \(output.metalContractFailures.joined(separator: ", ")); quality flags: \(output.qualityFlags.joined(separator: ", "))"
            ))
        }

        if timing.precisionLimitExceededDefault {
            findings.append(BottleneckFinding(
                kind: .precisionLimitFallback,
                severity: "high",
                summary: "Default Metal precision limit (0.01) rejects this diagram's coordinate span",
                evidence: "Throws LayoutExecutionError.precisionLimit on .metal (or falls back to CPU on .automatic) unless maximumCoordinateError is relaxed."
            ))
        }

        if timing.metalStages.isEmpty && (output.nodeCount > 1 || output.edgeCount > 0) {
            findings.append(BottleneckFinding(
                kind: .noMetalStagesSubmitted,
                severity: "high",
                summary: "No GPU compute stages were submitted in .metal mode",
                evidence: "0 Metal stages recorded; CPU stages: \(timing.cpuStagesInMetalMode.joined(separator: ", "))"
            ))
        }

        if !timing.metalStages.isEmpty && timing.gpuUtilizationFraction < 0.15 {
            findings.append(BottleneckFinding(
                kind: .lowGpuUtilization,
                severity: "medium",
                summary: "GPU kernel execution is < 15% of Metal wall-clock time",
                evidence: String(
                    format: "GPU kernel %.3f ms vs Metal total %.3f ms (%.1f%% utilization); CPU prep %.3f ms, overhead %.3f ms",
                    timing.metalGpuKernelMedianMs ?? 0,
                    timing.metalWarmMedianMs,
                    timing.gpuUtilizationFraction * 100.0,
                    timing.metalCpuPrepMedianMs,
                    timing.metalOverheadMedianMs
                )
            ))
        }

        if timing.submittedBatches >= 8 && (timing.metalGpuKernelMedianMs ?? 0) < timing.metalOverheadMedianMs {
            findings.append(BottleneckFinding(
                kind: .highMicroDispatchOverhead,
                severity: "high",
                summary: "Excessive sequential command-buffer dispatches dominate GPU kernel time",
                evidence: String(
                    format: "%d batches submitted (%.3f ms total GPU kernel vs %.3f ms CPU/dispatch overhead)",
                    timing.submittedBatches,
                    timing.metalGpuKernelMedianMs ?? 0,
                    timing.metalOverheadMedianMs
                )
            ))
        }

        if timing.speedupVsCPU < 0.85 && timing.metalWarmMedianMs > 0.25 {
            findings.append(BottleneckFinding(
                kind: .metalSlowerThanCPU,
                severity: "medium",
                summary: "Metal warm execution is slower than CPU on this workload",
                evidence: String(
                    format: "Speedup %.2fx (CPU %.3f ms vs Metal %.3f ms)",
                    timing.speedupVsCPU,
                    timing.cpuWarmMedianMs,
                    timing.metalWarmMedianMs
                )
            ))
        }

        let majorCPUOnlyMarkers = [
            "hierarchy-placement",
            "incremental-insertion",
            "obstacle-routing",
            "route-refinement",
            "visibility vertices and ordered shortest-path search",
            "ordered A* search",
            "BSP hierarchy and ordered visibility search",
            "seeded annealing",
            "edge routing",
            "frame overlap repair",
            "incoming group edge alignment"
        ]
        let matchedCPUStages = timing.cpuStagesInMetalMode.filter { stage in
            majorCPUOnlyMarkers.contains { stage.localizedCaseInsensitiveContains($0) }
        }
        if !matchedCPUStages.isEmpty && timing.gpuUtilizationFraction < 0.50 {
            findings.append(BottleneckFinding(
                kind: .unacceleratedPipelineStage,
                severity: "medium",
                summary: "Major algorithmic stages remain on CPU during .metal execution",
                evidence: "Retained CPU stages: \(matchedCPUStages.joined(separator: "; "))"
            ))
        }

        if timing.automaticChoseBackend == LayoutBackend.cpu.rawValue,
           timing.automaticFallbackReason == LayoutFallbackReason.belowThreshold.rawValue {
            findings.append(BottleneckFinding(
                kind: .thresholdFallback,
                severity: "info",
                summary: "Automatic backend selects CPU due to conservative size/edge threshold",
                evidence: "Nodes: \(output.nodeCount), Edges: \(output.edgeCount) -> fallbackReason: belowThreshold"
            ))
        }

        return findings
    }

    // MARK: - Report Persistence (JSON + Markdown + HTML)

    public static func writeReport(
        _ report: BackendComparativeReport,
        to directory: URL,
        renderImages: Bool = false
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try VisualStorage.writeJSON(report, directory.appendingPathComponent("benchmark-report.json"))
        let md = markdownReport(report)
        try md.write(to: directory.appendingPathComponent("benchmark-report.md"), atomically: true, encoding: .utf8)
        let html = htmlReport(report, renderImages: renderImages)
        try html.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    public static func markdownReport(_ report: BackendComparativeReport) -> String {
        var lines: [String] = []
        lines.append("# SwiftGraph CPU vs Metal Comparative Benchmark Report")
        lines.append("")
        lines.append("- **Generated**: `\(report.generatedAt)`")
        lines.append("- **Metal Device**: `\(report.deviceName)`")
        lines.append("- **Total Diagram Cases**: `\(report.totalCases)` across `\(report.families.count)` families (`\(report.trialsPerCase)` warm trials + 1 cold trial per backend)")
        lines.append("")

        let exactCount = report.cases.filter { $0.output.parityClassification == .exact }.count
        let floatEqCount = report.cases.filter { $0.output.parityClassification == .floatEquivalent }.count
        let heurDivCount = report.cases.filter { $0.output.parityClassification == .heuristicDivergent }.count
        let regCount = report.cases.filter { $0.output.parityClassification == .qualityRegression }.count
        let totalCpuMs = report.cases.map(\.timing.cpuWarmMedianMs).reduce(0, +)
        let totalMetalMs = report.cases.map(\.timing.metalWarmMedianMs).reduce(0, +)
        let totalGpuKernelMs = report.cases.compactMap(\.timing.metalGpuKernelMedianMs).reduce(0, +)
        let overallUtil = totalMetalMs > 0 ? (totalGpuKernelMs / totalMetalMs) * 100.0 : 0

        lines.append("## 1. Executive Summary")
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("|---|---|")
        lines.append("| **Exact Geometry Parity (`<= 1e-6`)** | **\(exactCount) / \(report.totalCases)** (\(String(format: "%.1f%%", Double(exactCount) / Double(max(1, report.totalCases)) * 100))) |")
        lines.append("| **Float-Equivalent Parity (`<= 0.05`)** | **\(floatEqCount) / \(report.totalCases)** |")
        lines.append("| **Heuristic Divergent (Organic/Bundling Float vs Double)** | **\(heurDivCount) / \(report.totalCases)** |")
        lines.append("| **Contract / Quality Regressions on Metal** | **\(regCount) / \(report.totalCases)** |")
        lines.append("| **Aggregate CPU Warm Time** | **\(String(format: "%.2f ms", totalCpuMs))** |")
        lines.append("| **Aggregate Metal Warm Time** | **\(String(format: "%.2f ms", totalMetalMs))** |")
        lines.append("| **Aggregate GPU Kernel Time** | **\(String(format: "%.2f ms", totalGpuKernelMs))** (\(String(format: "%.1f%%", overallUtil)) of Metal wall time) |")
        lines.append("| **Overall Suite Wall-Clock Speedup (CPU / Metal)** | **\(String(format: "%.2fx", totalCpuMs / max(1e-6, totalMetalMs)))** |")
        lines.append("")

        lines.append("## 2. Family-Level Comparative Summary")
        lines.append("")
        lines.append("| Family | Cases | Exact | Float-Eq | Heuristic-Div | Regressions | CPU Total (ms) | Metal Total (ms) | GPU Kernel (ms) | Mean GPU Util | Median Speedup | Faster on Metal |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for f in report.families {
            lines.append(String(
                format: "| `%@` | %d | %d | %d | %d | %d | %.2f | %.2f | %.2f | %.1f%% | %.2fx | %d/%d |",
                f.family,
                f.caseCount,
                f.exactParityCount,
                f.floatEquivalentCount,
                f.heuristicDivergentCount,
                f.qualityRegressionCount,
                f.cpuTotalWarmMs,
                f.metalTotalWarmMs,
                f.gpuKernelTotalMs,
                f.meanGpuUtilization * 100.0,
                f.medianSpeedup,
                f.fasterOnMetalCount,
                f.caseCount
            ))
        }
        lines.append("")

        lines.append("## 3. Automated Bottleneck & Metal Underutilization Findings")
        lines.append("")
        lines.append("| Bottleneck Category | Affected Cases | Description |")
        lines.append("|---|---:|---|")
        for kind in BottleneckKind.allCases {
            let count = report.bottleneckCounts[kind.rawValue] ?? 0
            lines.append("| `\(kind.rawValue)` | \(count) | \(bottleneckDescription(kind)) |")
        }
        lines.append("")

        // Top slowdowns & highest micro-dispatch overhead
        let slowestOnMetal = report.cases.sorted { $0.timing.speedupVsCPU < $1.timing.speedupVsCPU }.prefix(12)
        lines.append("### Top 12 Metal Slowdowns (Lowest CPU/Metal Speedup Ratio)")
        lines.append("")
        lines.append("| Case ID | Family | Nodes / Edges | CPU Warm (ms) | Metal Warm (ms) | GPU Kernel (ms) | GPU Util | Batches | Speedup | Key Bottlenecks |")
        lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---|")
        for c in slowestOnMetal {
            let bTags = c.bottlenecks.filter { $0.kind != .thresholdFallback }.map(\.kind.rawValue).joined(separator: ", ")
            lines.append(String(
                format: "| `%@` | `%@` | %d / %d | %.3f | %.3f | %.3f | %.1f%% | %d | **%.2fx** | %@ |",
                c.id,
                c.family,
                c.output.nodeCount,
                c.output.edgeCount,
                c.timing.cpuWarmMedianMs,
                c.timing.metalWarmMedianMs,
                c.timing.metalGpuKernelMedianMs ?? 0,
                c.timing.gpuUtilizationFraction * 100.0,
                c.timing.submittedBatches,
                c.timing.speedupVsCPU,
                bTags.isEmpty ? "none" : bTags
            ))
        }
        lines.append("")

        // Top speedups on Metal
        let fastestOnMetal = report.cases.sorted { $0.timing.speedupVsCPU > $1.timing.speedupVsCPU }.prefix(10)
        lines.append("### Top 10 Metal Speedups (Highest CPU/Metal Speedup Ratio)")
        lines.append("")
        lines.append("| Case ID | Family | Nodes / Edges | CPU Warm (ms) | Metal Warm (ms) | GPU Kernel (ms) | GPU Util | Batches | Speedup | Parity |")
        lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---|")
        for c in fastestOnMetal {
            lines.append(String(
                format: "| `%@` | `%@` | %d / %d | %.3f | %.3f | %.3f | %.1f%% | %d | **%.2fx** | `%@` |",
                c.id,
                c.family,
                c.output.nodeCount,
                c.output.edgeCount,
                c.timing.cpuWarmMedianMs,
                c.timing.metalWarmMedianMs,
                c.timing.metalGpuKernelMedianMs ?? 0,
                c.timing.gpuUtilizationFraction * 100.0,
                c.timing.submittedBatches,
                c.timing.speedupVsCPU,
                c.output.parityClassification.rawValue
            ))
        }
        lines.append("")

        lines.append("## 4. Complete Per-Case Comparative Table")
        lines.append("")
        lines.append("| Case ID | Family | N / E | Parity | Node RMS (Aligned) | Edge Max Dev | Crossing Delta | CPU (ms) | Metal (ms) | GPU (ms) | Util % | Batches | Speedup |")
        lines.append("|---|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for c in report.cases {
            let crossDelta = c.output.metricDeltas["crossings"] ?? 0
            lines.append(String(
                format: "| `%@` | `%@` | %d/%d | `%@` | %.3f | %.3f | %+.0f | %.3f | %.3f | %.3f | %.1f%% | %d | %.2fx |",
                c.id,
                c.family,
                c.output.nodeCount,
                c.output.edgeCount,
                c.output.parityClassification.rawValue,
                c.output.centroidAlignedNodeRMS,
                c.output.maxEdgePointDeviation,
                crossDelta,
                c.timing.cpuWarmMedianMs,
                c.timing.metalWarmMedianMs,
                c.timing.metalGpuKernelMedianMs ?? 0,
                c.timing.gpuUtilizationFraction * 100.0,
                c.timing.submittedBatches,
                c.timing.speedupVsCPU
            ))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func htmlReport(_ report: BackendComparativeReport, renderImages: Bool) -> String {
        var rows = ""
        for c in report.cases {
            let badgeColor: String
            switch c.output.parityClassification {
            case .exact: badgeColor = "#16a34a"
            case .floatEquivalent: badgeColor = "#2563eb"
            case .heuristicDivergent: badgeColor = "#d97706"
            case .qualityRegression: badgeColor = "#dc2626"
            }
            let speedupColor = c.timing.speedupVsCPU >= 1.0 ? "#16a34a" : "#dc2626"
            let mediaHTML: String
            if renderImages {
                mediaHTML = """
                <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-top:8px;">
                  <div><div style="font-size:11px;color:#475569;">CPU</div><img src="cases/\(c.id)/cpu.svg" style="max-width:100%;border:1px solid #e2e8f0;"/></div>
                  <div><div style="font-size:11px;color:#475569;">Metal</div><img src="cases/\(c.id)/metal.svg" style="max-width:100%;border:1px solid #e2e8f0;"/></div>
                  <div><div style="font-size:11px;color:#475569;">Overlay (CPU fuchsia / Metal cyan)</div><img src="cases/\(c.id)/overlay.svg" style="max-width:100%;border:1px solid #e2e8f0;"/></div>
                </div>
                """
            } else {
                mediaHTML = ""
            }
            let bottleneckBadges = c.bottlenecks.map {
                "<span style=\"display:inline-block;background:#f1f5f9;border:1px solid #cbd5e1;border-radius:4px;padding:1px 6px;margin:1px;font-size:11px;\">\($0.kind.rawValue)</span>"
            }.joined(separator: " ")

            rows += """
            <tr>
              <td><code>\(VisualRenderer.escape(c.id))</code><br/><small style="color:#64748b;">\(VisualRenderer.escape(c.title))</small>\(mediaHTML)</td>
              <td><code>\(VisualRenderer.escape(c.family))</code></td>
              <td style="text-align:right;">\(c.output.nodeCount) / \(c.output.edgeCount)</td>
              <td><span style="background:\(badgeColor);color:white;padding:2px 8px;border-radius:999px;font-size:12px;">\(c.output.parityClassification.rawValue)</span></td>
              <td style="text-align:right;">\(String(format: "%.3f", c.output.centroidAlignedNodeRMS))</td>
              <td style="text-align:right;">\(String(format: "%.3f", c.output.maxEdgePointDeviation))</td>
              <td style="text-align:right;">\(String(format: "%.3f", c.timing.cpuWarmMedianMs))</td>
              <td style="text-align:right;">\(String(format: "%.3f", c.timing.metalWarmMedianMs))</td>
              <td style="text-align:right;">\(String(format: "%.3f", c.timing.metalGpuKernelMedianMs ?? 0))</td>
              <td style="text-align:right;">\(String(format: "%.1f%%", c.timing.gpuUtilizationFraction * 100.0))</td>
              <td style="text-align:right;">\(c.timing.submittedBatches)</td>
              <td style="text-align:right;font-weight:600;color:\(speedupColor);">\(String(format: "%.2fx", c.timing.speedupVsCPU))</td>
              <td>\(bottleneckBadges)</td>
            </tr>
            """
        }

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8"/>
          <title>SwiftGraph CPU vs Metal Benchmark Report</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 24px; color: #0f172a; background: #f8fafc; }
            h1, h2 { color: #0f172a; }
            table { width: 100%; border-collapse: collapse; background: white; box-shadow: 0 1px 2px rgba(0,0,0,0.05); }
            th, td { border: 1px solid #e2e8f0; padding: 8px 10px; font-size: 13px; vertical-align: top; }
            th { background: #f1f5f9; text-align: left; }
            code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
          </style>
        </head>
        <body>
          <h1>SwiftGraph CPU vs Metal Comparative Benchmark Report</h1>
          <p>Device: <code>\(VisualRenderer.escape(report.deviceName))</code> · Cases: <strong>\(report.totalCases)</strong> · Trials/case: <strong>\(report.trialsPerCase)</strong></p>
          <table>
            <thead>
              <tr>
                <th>Case</th>
                <th>Family</th>
                <th>N / E</th>
                <th>Parity</th>
                <th>Aligned Node RMS</th>
                <th>Edge Max Dev</th>
                <th>CPU (ms)</th>
                <th>Metal (ms)</th>
                <th>GPU Kernel (ms)</th>
                <th>GPU Util</th>
                <th>Batches</th>
                <th>Speedup</th>
                <th>Bottlenecks</th>
              </tr>
            </thead>
            <tbody>
              \(rows)
            </tbody>
          </table>
        </body>
        </html>
        """
    }

    private static func bottleneckDescription(_ kind: BottleneckKind) -> String {
        switch kind {
        case .noMetalStagesSubmitted:
            return "Requested `.metal` backend completed with zero Metal stages submitted."
        case .lowGpuUtilization:
            return "Hardware GPU kernel time (`gpuSeconds`) is under 15% of total `.metal` wall-clock time."
        case .highMicroDispatchOverhead:
            return "More than 20 sequential command-buffer batches submitted with dispatch overhead exceeding GPU kernel time."
        case .metalSlowerThanCPU:
            return "Warm `.metal` wall-clock median is slower than `.cpu` (`speedup < 0.85x`)."
        case .unacceleratedPipelineStage:
            return "Major layout or routing phases (hierarchy placement, shortest-path search, A*, annealing) run on CPU during `.metal` mode."
        case .precisionLimitFallback:
            return "Default `MetalLayoutOptions.maximumCoordinateError` (`0.01`) rejects the diagram's coordinate span."
        case .thresholdFallback:
            return "`.automatic` backend falls back to `.cpu` due to conservative default node/edge thresholds."
        case .qualityRegression:
            return "Metal output introduces a visual contract failure or quality regression relative to CPU."
        }
    }

    public static func compareGraphs(
        id: String,
        family: String,
        cpuGraph: LayoutGraph,
        metalGraph: LayoutGraph
    ) -> OutputComparisonSummary {
        let cpuCase = VisualCase(id: id, family: family, title: id, configuration: ["backend": "cpu"], run: { VisualDrawing(graph: cpuGraph) })
        let metalCase = VisualCase(id: id, family: family, title: id, configuration: ["backend": "metal"], metal: true, run: { VisualDrawing(graph: metalGraph) })
        var cpuSnapshot = VisualSnapshot(case: cpuCase, drawing: VisualDrawing(graph: cpuGraph))
        var metalSnapshot = VisualSnapshot(case: metalCase, drawing: VisualDrawing(graph: metalGraph))
        let cpuVisualMetrics = VisualGeometry.measure(cpuSnapshot)
        let metalVisualMetrics = VisualGeometry.measure(metalSnapshot)
        cpuSnapshot.measuredMetrics = cpuVisualMetrics.values
        metalSnapshot.measuredMetrics = metalVisualMetrics.values
        return compareOutputs(
            cpuSnapshot: cpuSnapshot,
            metalSnapshot: metalSnapshot,
            cpuVisualMetrics: cpuVisualMetrics,
            metalVisualMetrics: metalVisualMetrics
        )
    }

    private static func durationMs(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1_000.0 + Double(c.attoseconds) / 1_000_000_000_000_000.0
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) * 0.5
        }
        return sorted[mid]
    }

    private static func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for v in values where seen.insert(v).inserted {
            result.append(v)
        }
        return result
    }
}
