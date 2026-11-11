import Foundation

/// Search bookkeeping for one channel grid, reused by every edge routed on it.
///
/// Small grids keep one flat buffer and a generation stamp, so starting a search clears nothing; grids too large for
/// that keep only the states a search touches. The flat buffer is raw memory, read through a value-typed `Session`,
/// because a search touches it millions of times and class-stored arrays pay an exclusivity check on every access.
final class ChannelSearchStorage {
    // MARK: - Nested types

    fileprivate struct Entry {
        var seen: UInt32 = 0
        var closed: UInt32 = 0
        var cost: Float = 0
        var previous: Int32 = -1
    }

    /// One search's view of the storage.
    struct Session {
        fileprivate let entries: UnsafeMutablePointer<Entry>?
        fileprivate let generation: UInt32
        fileprivate let storage: ChannelSearchStorage

        /// The best cost found so far for `state`, or infinity.
        @inline(__always)
        func cost(_ state: Int) -> Float {
            if let entries { return entries[state].seen == generation ? entries[state].cost : .infinity }
            return storage.sparse[state]?.cost ?? .infinity
        }

        func previous(_ state: Int) -> Int {
            if let entries { return Int(entries[state].previous) }
            return storage.sparse[state]?.previous ?? -1
        }

        @inline(__always)
        func update(_ state: Int, cost: Float, previous from: Int) {
            if let entries {
                entries[state].seen = generation
                entries[state].cost = cost
                entries[state].previous = Int32(from)
            } else {
                storage.sparse[state] = (cost, from, storage.sparse[state]?.isClosed ?? false)
            }
        }

        @inline(__always)
        func isClosed(_ state: Int) -> Bool {
            if let entries { return entries[state].closed == generation }
            return storage.sparse[state]?.isClosed ?? false
        }

        @inline(__always)
        func close(_ state: Int) {
            if let entries {
                entries[state].closed = generation
            } else {
                storage.sparse[state, default: (.infinity, -1, false)].isClosed = true
            }
        }
    }

    // MARK: - Properties

    /// State spaces up to this size are stored densely, at 16 bytes a state.
    static let denseLimit = 2_000_000

    private let count: Int
    private let entries: UnsafeMutablePointer<Entry>?
    private var generation: UInt32 = 0
    fileprivate var sparse: [Int: (cost: Float, previous: Int, isClosed: Bool)] = [:]

    // MARK: - Init

    init(states: Int) {
        count = states
        if states <= Self.denseLimit {
            let buffer = UnsafeMutablePointer<Entry>.allocate(capacity: states)
            buffer.initialize(repeating: Entry(), count: states)
            entries = buffer
        } else {
            entries = nil
        }
    }

    deinit {
        entries?.deinitialize(count: count)
        entries?.deallocate()
    }

    // MARK: - Search

    /// Forgets the previous search and starts a new one.
    func begin() -> Session {
        sparse.removeAll(keepingCapacity: true)
        generation &+= 1
        if generation == 0 {
            entries?.update(repeating: Entry(), count: count)
            generation = 1
        }
        return Session(entries: entries, generation: generation, storage: self)
    }
}
