import Foundation

/// How heavily routes laid so far use the channel grid, and what that costs a new route.
///
/// Usage is counted per span (routes running along it) and per vertex and axis (routes passing through it that way,
/// which a perpendicular route would cross). Each route's share is kept by owner, so a route can be taken out again
/// and laid elsewhere.
///
/// Negotiation, in the manner of PathFinder: a span holds one route, and each rip-up round (`escalate`) adds a
/// lasting history cost to every span that more routes share. PathFinder also raises the present cost each round;
/// that is left out, because corridors in dense drawings are genuinely over capacity and a rising present cost only
/// trades shared spans for jogs. The history step is small for the same reason: it breaks ties between near-equal
/// routes rather than forcing detours.
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

    /// The cost of running one pitch alongside one other route, and of crossing one. Crossings used to cost half;
    /// at the full penalty the topology benchmark draws 16–20% fewer crossings, with negotiation on or off, for about
    /// 15% more bends.
    let penalty: Int

    private let pitch: Float
    private var spanUsage: ChannelCounts
    private var passUsage: ChannelCounts
    private var owned: [ObjectIdentifier: Footprint] = [:]

    /// Routes over a span's capacity of one, summed over the negotiation rounds so far.
    private var history: ChannelCounts

    /// The cost of one unit of history per pitch: a tenth of the penalty.
    private var historyStep: Float { Float(penalty) / 10 }

    var isEmpty: Bool { owned.isEmpty }

    // MARK: - Init

    init(_ grid: ChannelGrid, penalty: Int) {
        self.penalty = penalty
        pitch = grid.pitch
        spanUsage = ChannelCounts(capacity: grid.vertexCount * 2)
        passUsage = ChannelCounts(capacity: grid.vertexCount * 2)
        history = ChannelCounts(capacity: grid.vertexCount * 2)
    }

    // MARK: - Reading

    /// Routes already running along `span`.
    func usage(ofSpan span: Int) -> Int { spanUsage[span] }

    /// Routes already passing through `vertex` along `axis`.
    func passes(through vertex: Int, along axis: ChannelGrid.Axis) -> Int { passUsage[vertex * 2 + axis.rawValue] }

    /// The cost of running `length` points along `span` beside the routes already there, plus its history.
    func cost(along span: Int, length: Float) -> Float {
        guard penalty > 0 else { return 0 }
        return Self.weight(spanUsage[span], history[span], penalty, historyStep) * length / pitch
    }

    /// The cost of passing through `vertex` along `axis`, crossing routes that pass through it the other way.
    func crossingCost(at vertex: Int, along axis: ChannelGrid.Axis) -> Float {
        guard penalty > 0 else { return 0 }
        let crossing = passUsage[vertex * 2 + axis.other.rawValue]
        return crossing == 0 ? 0 : Float(crossing * penalty)
    }

    /// The route `owner` laid.
    func footprint(of owner: ObjectIdentifier) -> Footprint? { owned[owner] }

    /// What `owner`'s route pays to share its spans with the other routes now laid, history included; crossings are
    /// left out.
    func sharingCost(of owner: ObjectIdentifier, _ grid: ChannelGrid) -> Float {
        guard penalty > 0, let footprint = owned[owner] else { return 0 }
        return footprint.spans.reduce(0) { total, span in
            total + Self.weight(spanUsage[span] - 1, history[span], penalty, historyStep) * grid.length(ofSpan: span)
                / pitch
        }
    }

    /// Length, in pitches, that routes beyond the first run along a shared span, summed over every span.
    func overuse(_ grid: ChannelGrid) -> Float {
        crowded.reduce(0) { $0 + Float(spanUsage[$1] - 1) * grid.length(ofSpan: $1) / pitch }
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

    /// Starts a negotiation round: every span more than one route shares gains one history unit per extra route.
    mutating func escalate() {
        for span in crowded { history[span] += spanUsage[span] - 1 }
    }

    /// Takes `owner`'s route out of the counts.
    mutating func remove(owner: ObjectIdentifier) {
        guard let footprint = owned.removeValue(forKey: owner) else { return }
        for span in footprint.spans { spanUsage[span] -= 1 }
        for pass in footprint.passes { passUsage[pass] -= 1 }
    }

    // MARK: - Helpers

    /// Spans more than one route runs along.
    private var crowded: Set<Int> {
        var spans = Set<Int>()
        for footprint in owned.values {
            for span in footprint.spans where spanUsage[span] > 1 { spans.insert(span) }
        }
        return spans
    }

    /// Cost per pitch of running beside `usage` routes on a span with `history` units.
    private static func weight(_ usage: Int, _ history: Int, _ penalty: Int, _ step: Float) -> Float {
        let present = Float(usage * penalty)
        return history == 0 ? present : present + Float(history) * step
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
