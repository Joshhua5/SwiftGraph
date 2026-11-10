import Foundation

/// A deterministic spanning forest, with iterative traversal for deep and cyclic input.
struct Forest {
    var roots: [Int] = []
    var children: [[Int]]
    var depth: [Int]
    var order: [Int] = []

    init(_ a: Adjacency, undirected: Bool = false, degreeRoots: Bool = false) {
        children = Array(repeating: [], count: a.nodes.count)
        depth = Array(repeating: 0, count: a.nodes.count)
        var seen = Set<Int>()
        let candidates: [Int]
        if degreeRoots {
            candidates = a.nodes.indices.sorted {
                a.neighbors[$0].count == a.neighbors[$1].count ? $0 < $1 : a.neighbors[$0].count > a.neighbors[$1].count
            }
        } else {
            candidates = a.nodes.indices.filter { a.incoming[$0].isEmpty } + Array(a.nodes.indices)
        }
        for root in candidates where !seen.contains(root) {
            roots.append(root)
            var stack: [(Int, Int?)] = [(root, nil)]
            while let (i, parent) = stack.popLast() {
                guard seen.insert(i).inserted else { continue }
                if let parent {
                    children[parent].append(i)
                    depth[i] = depth[parent] + 1
                }
                order.append(i)
                for j in (undirected ? a.neighbors[i] : a.outgoing[i]).reversed() where !seen.contains(j) {
                    stack.append((j, i))
                }
            }
        }
    }
}
