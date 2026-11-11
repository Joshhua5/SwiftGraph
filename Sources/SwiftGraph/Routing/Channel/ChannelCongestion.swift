import Foundation

/// How heavily routes laid so far use the channel grid, and what that costs a new route.
///
/// Usage is counted per span (routes running along it) and per vertex and axis (routes passing through it that way,
/// which a perpendicular route would cross). Each route's share is kept by owner, so a route can be taken out again
/// and laid elsewhere; a negotiation layer can sit on `add`, `remove` and the two cost reads.
struct ChannelCongestion {
    // MARK: - Nested types

    /// The grid elements one route occupies.
    struct Footprint {
        /// Span ids (`ChannelGrid.span(from:along:)`), including the two port stubs.
        var spans: [Int] = []

        /// Vertex passes, `vertex * 2 + axis`, one per axis the route runs along through the vertex.
        var passes: [Int] = []
    }

    // MARK: - Properties

    /// The cost of running one pitch alongside one other route; crossing one costs half that, but at least 1.
    let penalty: Int

    private let pitch: Float
    private var spanUsage: ChannelCounts
    private var passUsage: ChannelCounts
    private var owned: [ObjectIdentifier: Footprint] = [:]

    var isEmpty: Bool { owned.isEmpty }

    // MARK: - Init

    init(_ grid: ChannelGrid, penalty: Int) {
        self.penalty = penalty
        pitch = grid.pitch
        spanUsage = ChannelCounts(capacity: grid.vertexCount * 2)
        passUsage = ChannelCounts(capacity: grid.vertexCount * 2)
    }

    // MARK: - Reading

    /// Routes already running along `span`.
    func usage(ofSpan span: Int) -> Int { spanUsage[span] }

    /// Routes already passing through `vertex` along `axis`.
    func passes(through vertex: Int, along axis: ChannelGrid.Axis) -> Int { passUsage[vertex * 2 + axis.rawValue] }

    /// The cost of running `length` points along `span` beside the routes already there.
    func cost(along span: Int, length: Float) -> Float {
        guard penalty > 0 else { return 0 }
        let usage = spanUsage[span]
        return usage == 0 ? 0 : Float(usage * penalty) * length / pitch
    }

    /// The cost of passing through `vertex` along `axis`, crossing routes that pass through it the other way.
    func crossingCost(at vertex: Int, along axis: ChannelGrid.Axis) -> Float {
        guard penalty > 0 else { return 0 }
        let crossing = passUsage[vertex * 2 + axis.other.rawValue]
        return crossing == 0 ? 0 : Float(crossing * max(1, penalty / 2))
    }

    // MARK: - Updating

    /// Records `footprint` as `owner`'s; an owner already present is replaced.
    mutating func add(_ footprint: Footprint, owner: ObjectIdentifier) {
        guard penalty > 0 else { return }
        remove(owner: owner)
        for span in footprint.spans { spanUsage[span] += 1 }
        for pass in footprint.passes { passUsage[pass] += 1 }
        owned[owner] = footprint
    }

    /// Takes `owner`'s route out of the counts.
    mutating func remove(owner: ObjectIdentifier) {
        guard let footprint = owned.removeValue(forKey: owner) else { return }
        for span in footprint.spans { spanUsage[span] -= 1 }
        for pass in footprint.passes { passUsage[pass] -= 1 }
    }
}

/// Non-negative counts keyed by a dense id: an array while the key space is small, a dictionary beyond it. The
/// array is allocated on the first write, so a grid nobody counts on costs nothing.
struct ChannelCounts {
    /// Key spaces up to this size are stored densely.
    static let denseLimit = 4_000_000

    private var dense: [Int32] = []
    private var sparse: [Int: Int32] = [:]
    private let capacity: Int
    private let isDense: Bool

    init(capacity: Int) {
        self.capacity = capacity
        isDense = capacity <= Self.denseLimit
    }

    subscript(key: Int) -> Int {
        get {
            if isDense { return dense.isEmpty ? 0 : Int(dense[key]) }
            return Int(sparse[key] ?? 0)
        }
        set {
            if isDense {
                if dense.isEmpty { dense = Array(repeating: 0, count: capacity) }
                dense[key] = Int32(newValue)
            } else if newValue == 0 {
                sparse[key] = nil
            } else {
                sparse[key] = Int32(newValue)
            }
        }
    }
}
