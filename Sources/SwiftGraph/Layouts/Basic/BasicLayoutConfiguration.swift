import Foundation

/// Defaults match each synchronous layout. Only fields used by the selected style matter.
public struct BasicLayoutConfiguration: Sendable {
    public var radius: Float = 300
    public var cellSpacing: Float = 50
    private var configuredGridSize: Float?

    /// Orthogonal defaults to 100; alignment defaults to 20. Setting this familiar
    /// property explicitly configures either style's grid.
    public var gridSize: Float {
        get { configuredGridSize ?? 100 }
        set { configuredGridSize = newValue }
    }

    public var cellAssignment: [String: GridCell] = [:]
    public var defaultColumnWidth: Float = 150
    public var defaultRowHeight: Float = 100
    public var cellPadding: Float = 20
    public var gridPadding: Float = 40
    public var maxCellsPerRow: Int?
    public var spacing: Float = 40
    public var paddingX: Float = 10
    public var paddingY: Float = 10
    public var horizontalAlignment: AlignmentMode = .none
    public var verticalAlignment: AlignmentMode = .none

    /// Alias for alignment callers, sharing any explicit `gridSize` setting.
    public var alignmentGridSize: Float {
        get { configuredGridSize ?? 20 }
        set { configuredGridSize = newValue }
    }

    public var area: Rect = Rect(width: 100, height: 100)

    public var fillArea: Rect {
        get { area }
        set { area = newValue }
    }

    public var clearArea: Rect {
        get { area }
        set { area = newValue }
    }

    public var minSpacing: Float = 10

    public init(style: BasicLayoutStyle? = nil) { if style == .alignment { configuredGridSize = 20 } }

    func validate(_ style: BasicLayoutStyle) throws {
        let values: [Float]
        switch style {
        case .circular: values = [radius]
        case .tabular: values = [cellSpacing]
        case .orthogonal: values = [gridSize]
        case .partitionGrid:
            values = [defaultColumnWidth, defaultRowHeight, cellPadding]
            guard
                cellAssignment.values.filter({ $0.row >= 0 && $0.column >= 0 })
                    .allSatisfy({ $0.row < Int(Int32.max) && $0.column < Int(Int32.max) })
            else {
                throw LayoutExecutionError.invalidInput("Cell indices must fit in 32 bits.")
            }
        case .kandinsky:
            values = [gridPadding]
        case .verticalStack: values = [spacing, paddingX, paddingY]
        case .compactDisk: values = [spacing]
        case .alignment: values = [alignmentGridSize]
        case .fillArea, .clearArea: values = [area.x, area.y, area.width, area.height]
        case .removeOverlaps: values = [minSpacing]
        }
        guard values.allSatisfy(\.isFinite) else {
            throw LayoutExecutionError.invalidInput("Basic layout parameters must be finite.")
        }
    }

    func algorithm(_ style: BasicLayoutStyle) -> any LayoutAlgorithm {
        switch style {
        case .circular:
            let a = CircularLayoutAlgorithm()
            a.radius = radius
            return a
        case .tabular:
            let a = TabularLayoutAlgorithm()
            a.cellSpacing = cellSpacing
            return a
        case .orthogonal:
            let a = OrthogonalLayoutAlgorithm()
            a.gridSize = gridSize
            return a
        case .partitionGrid:
            let a = PartitionGridLayoutAlgorithm()
            a.cellAssignment = cellAssignment.mapValues { ($0.row, $0.column) }
            a.defaultColumnWidth = defaultColumnWidth
            a.defaultRowHeight = defaultRowHeight
            a.cellPadding = cellPadding
            return a
        case .kandinsky:
            let a = KandinskyLayoutAlgorithm()
            a.gridPadding = gridPadding
            a.maxCellsPerRow = maxCellsPerRow
            return a
        case .verticalStack:
            let a = VerticalStackLayoutAlgorithm()
            a.spacing = spacing
            a.paddingX = paddingX
            a.paddingY = paddingY
            return a
        case .alignment:
            let a = AlignmentLayoutAlgorithm()
            a.horizontalAlignment = horizontalAlignment
            a.verticalAlignment = verticalAlignment
            a.gridSize = alignmentGridSize
            return a
        case .fillArea: return FillAreaLayoutAlgorithm(area)
        case .clearArea: return ClearAreaLayoutAlgorithm(area)
        case .compactDisk:
            let a = CompactDiskLayoutAlgorithm()
            a.spacing = spacing
            return a
        case .removeOverlaps:
            let a = RemoveOverlapsLayoutAlgorithm()
            a.minSpacing = minSpacing
            return a
        }
    }
}
