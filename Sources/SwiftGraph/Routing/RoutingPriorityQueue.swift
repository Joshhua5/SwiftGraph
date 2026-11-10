import Foundation

/// Quaternary min-heap with priority-only tie handling, like System.Collections.Generic.PriorityQueue.
/// Router tie handling matters: equally short paths become inputs to later congestion/bundling passes.
struct RoutingPriorityQueue<Value> {
    private var items: [(Value, Float)] = []

    mutating func push(_ value: Value, priority: Float) {
        var i = items.count
        items.append((value, priority))
        while i > 0 {
            let p = (i - 1) / 4
            if priority >= items[p].1 { break }
            items[i] = items[p]
            i = p
        }
        items[i] = (value, priority)
    }

    mutating func pop() -> Value? {
        guard !items.isEmpty else { return nil }
        let result = items[0].0
        let last = items.removeLast()
        guard !items.isEmpty else { return result }
        // Searches pop millions of times; the raw buffer drops per-access bounds and exclusivity checks.
        items.withUnsafeMutableBufferPointer { items in
            let count = items.count
            var i = 0
            while i * 4 + 1 < count {
                let first = i * 4 + 1
                var best = first
                var bestPriority = items[first].1
                var j = first + 1
                while j < min(first + 4, count) {
                    if items[j].1 < bestPriority {
                        best = j
                        bestPriority = items[j].1
                    }
                    j += 1
                }
                if last.1 <= bestPriority { break }
                items[i] = items[best]
                i = best
            }
            items[i] = last
        }
        return result
    }
}
