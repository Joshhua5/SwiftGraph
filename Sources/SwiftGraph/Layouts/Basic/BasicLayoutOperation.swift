import Foundation

/// Placement runs on Metal; graph mutation and legacy edge routing stay with the caller.
public final class BasicLayoutOperation: LayoutExecutionReporting {
    public let style: BasicLayoutStyle
    public var configuration: BasicLayoutConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }

    public init(
        style: BasicLayoutStyle,
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configuration: BasicLayoutConfiguration? = nil
    ) {
        self.style = style
        self.backend = backend
        self.executor = executor
        self.configuration = configuration ?? .init(style: style)
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let start = ContinuousClock.now
        let configuration = self.configuration
        try Task.checkCancellation()
        try configuration.validate(style)
        let transaction = try LayoutTransaction(graph)
        // These styles carry or keep the routes rather than redraw them, so the routes keep their recorded style.
        if style == .removeOverlaps || style == .verticalStack || style == .alignment {
            transaction.working.routeStyle = graph.routeStyle
        }
        let computeStart = ContinuousClock.now
        let state = try LayoutStageScope.run("Plan", to: 0.1) {
            try basicPlacementState(transaction.working, style: style, configuration: configuration)
        }
        let style = self.style
        let executor = self.executor
        let backend = self.backend
        var result = try await LayoutStageScope.run("Placement", from: 0.1, to: 0.8) {
            let result = try await executor.placement(state, backend: backend)
            if result.bounds == nil { try configuration.algorithm(style).applyLayout(transaction.working) }
            return result
        }
        let routing = LayoutStageScope.begin("Route edges", from: 0.8)
        defer { routing.end() }
        if let bounds = result.bounds {
            let previous = transaction.working.nodes.map(\.bounds)
            for (node, bound) in zip(transaction.working.nodes, bounds) { node.bounds = bound }
            switch style {
            case .partitionGrid, .kandinsky: ChannelEdgeRouter().routeEdges(transaction.working)
            case .orthogonal:
                for e in transaction.working.edges where e.source !== e.target {
                    let a = e.source.center
                    let b = e.target.center
                    let x = (a.x + b.x) / 2
                    e.path = [a, Point(x: x, y: a.y), Point(x: x, y: b.y), b]
                }
                transaction.working.routeStyle = .orthogonal
            case .verticalStack: break
            case .removeOverlaps: followMovedNodes(transaction.working, from: previous)
            case .alignment: if previous != bounds { straightEdges(transaction.working) }
            default: straightEdges(transaction.working)
            }
            result.metrics.metalStages = [
                style == .removeOverlaps ? "force scan, pair separation and terminating sweep" : "node placement"
            ]
            result.metrics.cpuStages = ["snapshot and ordering"]
            if style == .removeOverlaps {
                result.metrics.cpuStages.append("edge path translation")
            } else if style != .verticalStack {
                result.metrics.cpuStages.append("edge routing")
            }
        } else {
            result.metrics.cpuStages = ["node placement"]
            if style != .verticalStack && style != .removeOverlaps { result.metrics.cpuStages.append("edge routing") }
        }
        result.metrics.computeSeconds = computeStart.duration(to: .now).seconds
        try transaction.commit(to: graph)
        result.metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = result.metrics
    }
}

private func alignmentCode(_ value: AlignmentMode) -> Int32 {
    switch value {
    case .none: 0
    case .left: 1
    case .center: 2
    case .right: 3
    case .top: 4
    case .middle: 5
    case .bottom: 6
    case .snapToGrid: 7
    }
}

func basicPlacementState(
    _ graph: LayoutGraph,
    style: BasicLayoutStyle,
    configuration c: BasicLayoutConfiguration
) throws -> MetalPlacementState {
    let nodes = graph.nodes
    let count = nodes.count
    var order = nodes.indices.filter { !nodes[$0].isGroup }
    var records = Array(repeating: SIMD4<Int32>(-1, -1, 0, 0), count: count)
    var scalars: [Float] = []
    var mode: UInt32 = 0
    var serial = false
    switch style {
    case .circular:
        let fitted = fittedCirclePlacement(order.map { nodes[$0].bounds }, minimum: c.radius)
        mode = 0
        scalars = [fitted.radius] + fitted.angles
    case .tabular, .orthogonal:
        mode = 1
        scalars = [style == .tabular ? c.cellSpacing : c.gridSize, Float(Int(ceil(sqrt(Double(order.count)))))]
    case .partitionGrid:
        mode = 2
        order = []
        let cells = c.cellAssignment.filter { $0.value.row >= 0 && $0.value.column >= 0 }
        let rows = (cells.values.map(\.row).max() ?? -1) + 1
        let columns = (cells.values.map(\.column).max() ?? -1) + 1
        for i in nodes.indices {
            if let cell = cells[nodes[i].id] {
                records[i] = SIMD4(Int32(cell.row), Int32(cell.column), 0, 0)
                order.append(i)
            }
        }
        scalars = [c.defaultColumnWidth, c.defaultRowHeight, c.cellPadding, Float(rows), Float(columns)]
    case .kandinsky:
        mode = 3
        let a = Adjacency(graph)
        let layers = a.layers(maxWidth: c.maxCellsPerRow ?? .max)
        let indices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element, $0.offset) })
        order = []
        for (r, layer) in layers.enumerated() {
            for (column, i) in layer.enumerated() {
                let index = indices[required: a.nodes[i]]
                records[index] = SIMD4(Int32(r), Int32(column), 0, 0)
                order.append(index)
            }
        }
        scalars = [c.gridPadding]
    case .compactDisk:
        mode = 4
        order.sort { nodes[$0].width * nodes[$0].height > nodes[$1].width * nodes[$1].height }
        scalars = [c.spacing]
    case .fillArea:
        mode = 5
        let ratio = c.area.width > 0 && c.area.height > 0 ? c.area.width / c.area.height : 1
        let proposed = ceil(sqrt(Double(order.count) * Double(ratio)))
        guard proposed.isFinite, proposed < Double(Int.max) else {
            throw LayoutExecutionError.invalidInput("Fill-area aspect ratio is too large.")
        }
        let columns = min(max(1, order.count), max(1, Int(proposed)))
        let rows = (order.count + columns - 1) / columns
        scalars = [c.area.x, c.area.y, c.area.width, c.area.height, Float(columns), Float(max(1, rows))]
    case .verticalStack:
        mode = 6
        order = Array(nodes.indices)
        order.sort { nodes[$0].id.compare(nodes[$1].id, options: .numeric) == .orderedAscending }
        scalars = [c.spacing, c.paddingX, c.paddingY]
    case .alignment:
        mode = 7
        order = Array(nodes.indices)
        scalars = [c.alignmentGridSize]
        records = nodes.map { _ in SIMD4(alignmentCode(c.horizontalAlignment), alignmentCode(c.verticalAlignment), 0, 0)
        }
        let horizontal = alignmentCode(c.horizontalAlignment)
        let vertical = alignmentCode(c.verticalAlignment)
        let movesX = (horizontal >= 1 && horizontal <= 3) || (horizontal == 7 && c.alignmentGridSize > 0)
        let movesY = (vertical >= 4 && vertical <= 6) || (vertical == 7 && c.alignmentGridSize > 0)
        if !movesX && !movesY { order = [] }
    case .clearArea:
        mode = 8
        serial = true
        order = nodes.indices.filter { nodes[$0].bounds.intersects(c.area) }
        scalars = [c.area.x, c.area.y, c.area.width, c.area.height]
    case .removeOverlaps:
        mode = 9
        serial = true
        scalars = [c.minSpacing]
    }
    if style == .removeOverlaps {
        var conflicts = false
        for a in order.indices {
            for b in (a + 1)..<order.count {
                let x = nodes[order[a]].bounds
                let y = nodes[order[b]].bounds
                let delta = y.center - x.center
                // Same tolerance as forceScan / separateOverlaps, so "already clear" means what they mean.
                let tolerance = spacingTolerance(x, y, spacing: c.minSpacing)
                let forceConflict =
                    abs(delta.x) < (x.width + y.width) / 2 + c.minSpacing - tolerance
                    && abs(delta.y) < (x.height + y.height) / 2 + c.minSpacing - tolerance
                let pairConflict =
                    min(x.right, y.right) - max(x.left, y.left) + c.minSpacing > tolerance
                    && min(x.bottom, y.bottom) - max(x.top, y.top) + c.minSpacing > tolerance
                if forceConflict || pairConflict {
                    conflicts = true
                    break
                }
            }
            if conflicts { break }
        }
        if !conflicts { order = [] }
    }
    let size = Double(nodes.map { max($0.width, $0.height) }.max() ?? 0)
    let coordinate = Double(nodes.map { max(abs($0.x), abs($0.y)) }.max() ?? 0)
    let parameters = Double(scalars.map(abs).max() ?? 0)
    let magnitude: Double
    switch style {
    case .circular:
        let radius = Double(scalars[0])
        magnitude = (2 * radius + 50 + size) * 4
    case .tabular, .orthogonal:
        magnitude = (size + abs(Double(scalars[0]))) * ceil(sqrt(Double(order.count))) * 4 + size
    case .partitionGrid:
        let usedRows = Double((records.map { max(-1, $0.x) }.max() ?? -1) + 1)
        let usedColumns = Double((records.map { max(-1, $0.y) }.max() ?? -1) + 1)
        magnitude =
            max(
                usedRows * max(abs(Double(c.defaultRowHeight)), size + 2 * abs(Double(c.cellPadding))),
                usedColumns * max(abs(Double(c.defaultColumnWidth)), size + 2 * abs(Double(c.cellPadding)))
            ) * 4 + size
    case .kandinsky:
        let rows = records.map { $0.x }.max() ?? 0
        let columns = records.map { $0.y }.max() ?? 0
        magnitude = Double(max(rows, columns) + 1) * (size + abs(Double(c.gridPadding))) * 4 + size
    case .compactDisk: magnitude = (size + abs(Double(c.spacing))) * sqrt(Double(order.count)) * 4
    case .fillArea: magnitude = (parameters + size) * 4
    case .verticalStack:
        magnitude =
            (size + abs(Double(c.spacing))) * Double(order.count) * 4 + abs(Double(c.paddingX))
            + abs(Double(c.paddingY))
    case .alignment: magnitude = (coordinate + size + parameters) * 4
    case .clearArea: magnitude = (coordinate + parameters + Double(max(1, order.count)) * (size + 10)) * 4
    case .removeOverlaps: magnitude = (coordinate + size + parameters + 1) * Double(max(1, count)) * 4
    }
    var discreteSafe = true
    if style == .alignment && c.alignmentGridSize > 0 {
        for node in nodes {
            for (value, mode) in [(node.x, c.horizontalAlignment), (node.y, c.verticalAlignment)]
            where mode == .snapToGrid {
                // The GPU snaps with rint(x / grid). A quotient within a few ulps of a half could round to the other
                // grid line if the division is off by an ulp, so it is unsafe. An exact half (the Float quotient equals
                // the true one and is exactly k + 0.5) rounds half-to-even identically on both sides, so it stays safe.
                let q = value / c.alignmentGridSize
                let d = abs(q - q.rounded(.toNearestOrEven))
                let exactHalf = d == 0.5 && Double(q) == Double(value) / Double(c.alignmentGridSize)
                if !exactHalf && d > 0 && abs(d - 0.5) <= Float(0.5).ulp * 8 { discreteSafe = false }
            }
        }
    } else if style == .removeOverlaps {
        // Force scan groups equal centers and uses stable tie order. Near-coincident
        // centers within a few ULPs are rejected for explicit precision protection.
        for horizontal in [true, false] {
            let key: (Int) -> Float = { horizontal ? nodes[$0].center.x : nodes[$0].center.y }
            let sorted = order.sorted { key($0) == key($1) ? $0 < $1 : key($0) < key($1) }
            for k in 1..<max(1, sorted.count) {
                let a = sorted[k - 1]
                let b = sorted[k]
                let ka = key(a)
                let kb = key(b)
                if ka != kb && abs(ka - kb) <= max(abs(ka).ulp, abs(kb).ulp) * 8 { discreteSafe = false }
            }
        }
    }
    let participating = Set(order)
    return MetalPlacementState(
        bounds: nodes.map(\.bounds),
        flags: nodes.indices.map { (nodes[$0].isGroup ? 1 : 0) | (participating.contains($0) ? 8 : 0) },
        records: records,
        order: order.map(UInt32.init),
        scalars: scalars,
        mode: mode,
        resource: "BasicLayouts",
        conservativeMagnitude: magnitude,
        serial: serial,
        discreteGeometrySafe: discreteSafe
    )
}
