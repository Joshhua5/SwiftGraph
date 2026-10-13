import Foundation

/// Gansner et al. network-simplex ranking: minimum total edge length subject to `rank(head) >= rank(tail) + 1`.
/// Deterministic: ties resolve by index. Parallel edges merge into one weighted edge, and each weakly connected
/// component is ranked on its own from rank 0. The input must be acyclic.
enum DirectedLayering {
    private struct Edge { var tail: Int, head: Int, weight: Int }

    static func ranks(count: Int, edges input: [(Int, Int)]) -> [Int] {
        var weights: [[Int]: Int] = [:]
        for (u, v) in input where u != v { weights[[u, v], default: 0] += 1 }
        let edges = weights.map { Edge(tail: $0.key[0], head: $0.key[1], weight: $0.value) }
            .sorted { ($0.tail, $0.head) < ($1.tail, $1.head) }
        var incident = Array(repeating: [Int](), count: count)
        for (i, e) in edges.enumerated() { incident[e.tail].append(i); incident[e.head].append(i) }
        var result = Array(repeating: 0, count: count), seen = Array(repeating: false, count: count)
        for seed in 0..<count where !seen[seed] {
            var members = [seed], cursor = 0; seen[seed] = true
            while cursor < members.count {
                for i in incident[members[cursor]] {
                    let other = edges[i].tail == members[cursor] ? edges[i].head : edges[i].tail
                    if !seen[other] { seen[other] = true; members.append(other) }
                }
                cursor += 1
            }
            members.sort()
            let local = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($0.element, $0.offset) })
            let part = Set(members.flatMap { incident[$0] }).sorted().map { edges[$0] }
                .map { Edge(tail: local[$0.tail]!, head: local[$0.head]!, weight: $0.weight) }
            let ranked = solve(count: members.count, edges: part)
            for (i, node) in members.enumerated() { result[node] = ranked[i] }
        }
        return result
    }

    private static func solve(count: Int, edges: [Edge]) -> [Int] {
        var rank = longestPath(count: count, edges: edges)
        guard count > 2, !edges.isEmpty, count * edges.count <= 4_000_000 else { return normalized(rank) }
        var incident = Array(repeating: [Int](), count: count)
        for (i, e) in edges.enumerated() { incident[e.tail].append(i); incident[e.head].append(i) }
        func slack(_ e: Int) -> Int { rank[edges[e].head] - rank[edges[e].tail] - 1 }
        func other(_ e: Int, _ v: Int) -> Int { edges[e].tail == v ? edges[e].head : edges[e].tail }

        // Feasible tight spanning tree: grow along zero-slack edges, shifting the tree by the smallest slack when stuck.
        var inTree = Array(repeating: false, count: count), tree = Set<Int>(), nodes = [0]
        inTree[0] = true
        func grow() {
            var stack = nodes
            while let v = stack.popLast() {
                for e in incident[v] where !inTree[other(e, v)] && slack(e) == 0 {
                    let w = other(e, v); inTree[w] = true; nodes.append(w); tree.insert(e); stack.append(w)
                }
            }
        }
        grow()
        while nodes.count < count {
            var best: Int?
            for e in edges.indices where inTree[edges[e].tail] != inTree[edges[e].head] && (best == nil || slack(e) < slack(best!)) { best = e }
            guard let edge = best else { return normalized(rank) }
            let delta = inTree[edges[edge].head] ? -slack(edge) : slack(edge)
            for v in nodes { rank[v] += delta }
            grow()
        }

        var parentEdge = Array(repeating: -1, count: count), low = Array(repeating: 0, count: count), lim = low
        var cut: [Int: Int] = [:]
        var post: [Int] = []
        func numbering() {
            parentEdge = Array(repeating: -1, count: count); post = []
            var number = 1, stack: [(node: Int, next: Int)] = [(0, 0)], visited = Array(repeating: false, count: count)
            visited[0] = true; low[0] = 1
            while !stack.isEmpty {
                let (v, k) = stack[stack.count - 1]
                if k < incident[v].count {
                    stack[stack.count - 1].next += 1
                    let e = incident[v][k], w = other(e, v)
                    if tree.contains(e) && !visited[w] { visited[w] = true; parentEdge[w] = e; low[w] = number; stack.append((w, 0)) }
                } else {
                    lim[v] = number; number += 1; post.append(v); stack.removeLast()
                }
            }
        }
        func cutValues() {
            cut = [:]
            for child in post where parentEdge[child] >= 0 {
                let pe = parentEdge[child], childIsTail = edges[pe].tail == child
                var value = edges[pe].weight
                for e in incident[child] where e != pe {
                    let isOut = edges[e].tail == child
                    let pointsToHead = isOut == childIsTail
                    value += pointsToHead ? edges[e].weight : -edges[e].weight
                    if tree.contains(e) { value += pointsToHead ? -cut[e]! : cut[e]! }
                }
                cut[pe] = value
            }
        }
        numbering(); cutValues()
        for _ in 0..<(2 * count + 16) {
            if RoutingCompute.isCancelled { break }
            var leave: Int?
            for e in tree.sorted() where cut[e]! < 0 && (leave == nil || cut[e]! < cut[leave!]!) { leave = e }
            guard let out = leave else { break }
            // The enter edge crosses the cut the other way and has the least slack.
            let tail = edges[out].tail, head = edges[out].head
            let flip = lim[tail] > lim[head], root = flip ? head : tail
            func inSubtree(_ v: Int) -> Bool { low[root] <= lim[v] && lim[v] <= lim[root] }
            var enter: Int?
            for e in edges.indices where flip == inSubtree(edges[e].tail) && flip != inSubtree(edges[e].head) {
                if enter == nil || slack(e) < slack(enter!) { enter = e }
            }
            guard let into = enter else { break }
            tree.remove(out); tree.insert(into)
            numbering(); cutValues()
            for v in post.reversed() where parentEdge[v] >= 0 {
                let pe = parentEdge[v], parent = other(pe, v)
                rank[v] = rank[parent] + (edges[pe].tail == v ? -1 : 1)
            }
        }
        return normalized(rank)
    }

    private static func longestPath(count: Int, edges: [Edge]) -> [Int] {
        var rank = Array(repeating: 0, count: count), pending = Array(repeating: 0, count: count)
        var outgoing = Array(repeating: [Int](), count: count)
        for e in edges { outgoing[e.tail].append(e.head); pending[e.head] += 1 }
        var ready = (0..<count).filter { pending[$0] == 0 }, cursor = 0
        while cursor < ready.count {
            let v = ready[cursor]; cursor += 1
            for w in outgoing[v] { rank[w] = max(rank[w], rank[v] + 1); pending[w] -= 1; if pending[w] == 0 { ready.append(w) } }
        }
        return rank
    }

    private static func normalized(_ rank: [Int]) -> [Int] {
        let low = rank.min() ?? 0
        return rank.map { $0 - low }
    }
}
