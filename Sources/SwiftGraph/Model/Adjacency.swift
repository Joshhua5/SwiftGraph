struct Adjacency {
    var nodes: [LayoutNode]
    var index: [LayoutNode: Int]
    var outgoing: [[Int]]
    var incoming: [[Int]]
    var neighbors: [[Int]]

    init(_ graph: LayoutGraph, excludingGroups: Bool = false) {
        nodes = graph.nodes.filter { !excludingGroups || !$0.isGroup }
        index = Dictionary(nodes.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        outgoing = Array(repeating: [], count: nodes.count)
        incoming = outgoing
        neighbors = outgoing
        for e in graph.edges {
            guard let s = index[e.source], let t = index[e.target], s != t else { continue }
            outgoing[s].append(t)
            incoming[t].append(s)
            neighbors[s].append(t)
            neighbors[t].append(s)
        }
    }

    func components() -> [[Int]] {
        var seen = Set<Int>()
        var result: [[Int]] = []
        for seed in nodes.indices where !seen.contains(seed) {
            var queue = [seed]
            var cursor = 0
            seen.insert(seed)
            while cursor < queue.count {
                for next in neighbors[queue[cursor]] where seen.insert(next).inserted { queue.append(next) }
                cursor += 1
            }
            result.append(queue)
        }
        return result
    }

    func layers(maxWidth: Int = .max) -> [[Int]] {
        guard !nodes.isEmpty else { return [] }
        var degree = incoming.map(\.count)
        var ranks = Array(repeating: -1, count: nodes.count)
        var layers: [[Int]] = []
        var queue = nodes.indices.filter { degree[$0] == 0 }
        var cursor = 0
        func assign(_ v: Int) {
            var rank = incoming[v].map { ranks[$0] + 1 }.max() ?? 0
            while rank < layers.count && layers[rank].count >= max(1, maxWidth) { rank += 1 }
            while layers.count <= rank { layers.append([]) }
            ranks[v] = rank
            layers[rank].append(v)
            for next in outgoing[v] where ranks[next] < 0 {
                degree[next] -= 1
                if degree[next] == 0 { queue.append(next) }
            }
        }
        for seed in nodes.indices {
            while cursor < queue.count {
                let v = queue[cursor]
                cursor += 1
                if ranks[v] < 0 { assign(v) }
            }
            if ranks[seed] < 0 { assign(seed) }
        }
        while cursor < queue.count {
            let v = queue[cursor]
            cursor += 1
            if ranks[v] < 0 { assign(v) }
        }
        return layers.filter { !$0.isEmpty }
    }
}
