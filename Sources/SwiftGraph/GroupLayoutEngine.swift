/// Shared synchronous/asynchronous composition geometry. All mutations target a transaction copy.
struct GroupLayoutEngine {
    let graph: LayoutGraph
    let groups: [LayoutNode]
    let padding: Float
    private let containers: [LayoutNode: LayoutNode]
    private let descendants: [LayoutNode: [LayoutNode]]
    private let ownedEdges: [LayoutNode: [LayoutEdge]]

    init(_ graph: LayoutGraph, padding: Float) throws {
        guard padding.isFinite, padding >= 0 else {
            throw LayoutExecutionError.invalidInput("Group padding must be finite and nonnegative.")
        }
        self.graph = graph; self.padding = padding
        let members = Set(graph.nodes)
        guard members.count == graph.nodes.count, !members.contains(graph.root) else {
            throw LayoutExecutionError.invalidInput("Group membership must contain unique nodes and exclude the root.")
        }
        var owners: [LayoutNode: LayoutNode] = [:], order: [LayoutNode] = []
        var stack = [(graph.root, false)], active = Set<LayoutNode>(), seen = Set<LayoutNode>()
        while let (node, post) = stack.popLast() {
            if post { active.remove(node); order.append(node); continue }
            guard !active.contains(node) else { throw GraphError.cyclicGroupHierarchy }
            guard seen.insert(node).inserted else {
                throw LayoutExecutionError.invalidInput("Each node must have exactly one group owner.")
            }
            guard node.isGroup || node.children.isEmpty else {
                throw LayoutExecutionError.invalidInput("Only group nodes can contain children.")
            }
            if node.isGroup { try node.groupFrame?.validate() }
            active.insert(node); stack.append((node, true))
            for child in node.children.reversed() {
                // A detached view's root is not the real parent of its direct members.
                guard members.contains(child), node === graph.root || child.parent === node else {
                    throw LayoutExecutionError.invalidInput("Group membership and hierarchy must agree.")
                }
                if node === graph.root, let parent = child.parent, members.contains(parent) {
                    throw LayoutExecutionError.invalidInput("A root child cannot also belong to a registered group.")
                }
                owners[child] = node; stack.append((child, false))
            }
        }
        guard seen.count == members.count + 1 else {
            throw LayoutExecutionError.invalidInput("Every registered node must be reachable from the group root.")
        }
        var contents: [LayoutNode: [LayoutNode]] = [:]
        for node in order {
            contents[node] = node.children.flatMap { [$0] + (contents[$0] ?? []) }
        }
        var edges: [LayoutNode: [LayoutEdge]] = [:]
        for edge in graph.edges {
            guard members.contains(edge.source), members.contains(edge.target) else {
                throw LayoutExecutionError.invalidInput("Every group edge endpoint must be registered.")
            }
            var ancestors = Set<LayoutNode>(), current = owners[edge.source]
            while let node = current { ancestors.insert(node); current = owners[node] }
            current = owners[edge.target]
            while let node = current, !ancestors.contains(node) { current = owners[node] }
            guard let owner = current else { throw LayoutExecutionError.invalidInput("Edge endpoints need a common container.") }
            edges[owner, default: []].append(edge)
        }
        groups = order.filter(\.isGroup); containers = owners; descendants = contents; ownedEdges = edges
    }

    struct Projection {
        let graph: LayoutGraph
        let nodes: [(original: LayoutNode, proxy: LayoutNode)]
        let edges: [(original: LayoutEdge, proxy: LayoutEdge)]
        let allEdges: [LayoutEdge]
    }

    func projection(for group: LayoutNode) -> Projection {
        let local = LayoutGraph(), origin = Point(x: group.x, y: group.y)
        var mapping: [LayoutNode: LayoutNode] = [:]
        let nodes = group.children.map { node -> (original: LayoutNode, proxy: LayoutNode) in
            let proxy = LayoutNode(id: node.id, width: node.width, height: node.height, data: node.data)
            proxy.bounds = node.bounds.translated(by: .zero - origin)
            proxy.name = node.name; proxy.tags = node.tags; proxy.metadata = node.metadata
            local.addNode(proxy)
            mapping[node] = proxy
            for descendant in descendants[node] ?? [] { mapping[descendant] = proxy }
            return (node, proxy)
        }
        var edges: [(original: LayoutEdge, proxy: LayoutEdge)] = []
        for edge in graph.edges {
            guard let source = mapping[edge.source], let target = mapping[edge.target],
                  source !== target || (edge.source === edge.target && group.children.contains(edge.source)) else { continue }
            let proxy = LayoutEdge(source: source, target: target, data: edge.data)
            proxy.labelBounds = edge.labelBounds.translated(by: .zero - origin)
            let direct = containers[edge.source] === group && containers[edge.target] === group
            if direct {
                proxy.path = edge.path.map { $0 - origin }
                proxy.sourcePort = edge.sourcePort; proxy.targetPort = edge.targetPort
                proxy.sourcePortCandidates = edge.sourcePortCandidates; proxy.targetPortCandidates = edge.targetPortCandidates
                edges.append((edge, proxy))
            }
            local.addEdge(proxy)
        }
        return Projection(graph: local, nodes: nodes, edges: edges, allEdges: local.edges)
    }

    func accept(_ projection: Projection, in group: LayoutNode) throws {
        guard projection.graph.nodes == projection.nodes.map(\.proxy),
              projection.graph.edges == projection.allEdges,
              projection.graph.nodes.allSatisfy({ !$0.isGroup && $0.children.isEmpty && $0.parent === projection.graph.root }),
              projection.graph.root.children == projection.graph.nodes else {
            throw LayoutExecutionError.invalidInput("Group layout cores must preserve proxy topology.")
        }
        _ = try GraphCheckpoint(projection.graph)
        guard projection.graph.nodes.allSatisfy({ $0.bounds.right.isFinite && $0.bounds.bottom.isFinite }),
              projection.graph.edges.allSatisfy({ edge in
                  edge.path.allSatisfy { $0.x.isFinite && $0.y.isFinite } &&
                  [edge.labelBounds.x, edge.labelBounds.y, edge.labelBounds.right, edge.labelBounds.bottom].allSatisfy(\.isFinite) &&
                  edge.labelBounds.width >= 0 && edge.labelBounds.height >= 0
              }) else { throw LayoutExecutionError.invalidInput("Group cores must return finite geometry and nonnegative label dimensions.") }
        for (node, proxy) in projection.nodes where node.isGroup {
            guard proxy.width >= node.width, proxy.height >= node.height else {
                throw LayoutExecutionError.invalidInput("A parent layout cannot shrink a measured group frame.")
            }
        }
        // Some point-oriented cores (notably balloon and small circular layouts) still
        // overlap large rectangles. Repair sibling frames before moving their rigid contents.
        let overlapsFrame = projection.nodes.enumerated().contains { i, a in
            projection.nodes.dropFirst(i + 1).contains { b in
                (a.original.isGroup || b.original.isGroup) && a.proxy.bounds.intersects(b.proxy.bounds)
            }
        }
        if overlapsFrame { try RemoveOverlapsLayoutAlgorithm().applyLayout(projection.graph) }
        let origin = Point(x: group.x, y: group.y)
        for (node, proxy) in projection.nodes {
            if node.isGroup {
                moveSubtree(node, by: Point(x: proxy.x + origin.x - node.x, y: proxy.y + origin.y - node.y))
                node.width = proxy.width; node.height = proxy.height
                updateFrameRectangles(node)
            } else { node.bounds = proxy.bounds.translated(by: origin) }
            for key in [GraphMetadataKeys.fixed, GraphMetadataKeys.layoutSubset, GraphMetadataKeys.pageRank, GraphMetadataKeys.cluster] {
                node.metadata[key] = proxy.metadata[key]
            }
        }
        for (edge, proxy) in projection.edges {
            edge.path = proxy.path.map { $0 + origin }; edge.labelBounds = proxy.labelBounds.translated(by: origin)
            edge.sourcePort = proxy.sourcePort; edge.targetPort = proxy.targetPort
            edge.sourcePortCandidates = proxy.sourcePortCandidates; edge.targetPortCandidates = proxy.targetPortCandidates
        }
    }

    /// Real endpoint/obstacle membership; the shared scene adds protected title rectangles.
    func routingGraph(for group: LayoutNode, allOwnedEdges: Bool = false) -> LayoutGraph {
        let routing = subgraph(graph, nodes: descendants[group] ?? [])
        let scene = ObstaclePolyline.Scene(routing.nodes)
        routing.edges = (ownedEdges[group] ?? []).filter { edge in
            if allOwnedEdges { return true }
            guard edge.source !== edge.target else { return false }
            let direct = containers[edge.source] === group && containers[edge.target] === group
            let attached = edge.path.first.map(edge.source.bounds.contains) == true && edge.path.last.map(edge.target.bounds.contains) == true
            return !direct || !attached || !scene.clear(edge.path, edge)
        }
        return routing
    }

    func finish(_ group: LayoutNode, routed: [LayoutEdge]) throws {
        // A moved cross-group route needs its measured label moved with it.
        centerLabels(on: routed)
        guard group !== graph.root else { return }
        let options = options(for: group), p = options.padding
        var envelope: Rect?
        func include(_ rect: Rect) { envelope = envelope.map { $0.union(rect) } ?? rect }
        for node in group.children { include(node.bounds) }
        for edge in ownedEdges[group] ?? [] {
            for point in edge.path { include(Rect(x: point.x, y: point.y)) }
            if edge.labelBounds.width > 0 && edge.labelBounds.height > 0 { include(edge.labelBounds) }
        }
        let content = envelope ?? Rect(x: group.x, y: group.y)
        group.width = max(options.minimumSize.width, max(content.width, options.headerSize.width) + p.left + p.right)
        group.height = max(options.minimumSize.height, content.height + options.headerSize.height + p.top + p.bottom)
        let delta = Point(x: group.x + p.left - content.x, y: group.y + p.top + options.headerSize.height - content.y)
        moveContents(group, by: delta)
        updateFrameRectangles(group)
        guard [group.width, group.height, group.bounds.right, group.bounds.bottom].allSatisfy(\.isFinite) else {
            throw LayoutExecutionError.invalidInput("Group frame dimensions overflowed.")
        }
    }

    private func centerLabels(on routed: [LayoutEdge]) {
        for edge in routed where edge.labelBounds.width > 0 && edge.labelBounds.height > 0 {
            let lengths = zip(edge.path, edge.path.dropFirst()).map { ($1 - $0).length }
            var remaining = lengths.reduce(0, +) / 2
            for (i, length) in lengths.enumerated() {
                if remaining <= length, length > 0 {
                    let p = edge.path[i] + (edge.path[i + 1] - edge.path[i]) * (remaining / length)
                    edge.labelBounds.x = p.x - edge.labelBounds.width / 2
                    edge.labelBounds.y = p.y - edge.labelBounds.height / 2
                    break
                }
                remaining -= length
            }
        }
    }

    private func options(for group: LayoutNode) -> GroupFrameOptions {
        group.groupFrame ?? GroupFrameOptions(padding: LayoutInsets(padding))
    }
    private func updateFrameRectangles(_ group: LayoutNode) {
        let options = options(for: group), p = options.padding
        let width = max(0, group.width - p.left - p.right)
        group.groupHeaderBounds = Rect(x: group.x + p.left, y: group.y + p.top, width: width, height: options.headerSize.height)
        group.groupContentBounds = Rect(x: group.x + p.left, y: group.y + p.top + options.headerSize.height,
                                       width: width, height: max(0, group.height - p.top - p.bottom - options.headerSize.height))
    }
    private func moveSubtree(_ node: LayoutNode, by delta: Point) {
        node.bounds = node.bounds.translated(by: delta)
        node.groupContentBounds = node.groupContentBounds?.translated(by: delta)
        node.groupHeaderBounds = node.groupHeaderBounds?.translated(by: delta)
        moveContents(node, by: delta)
    }
    private func moveContents(_ group: LayoutNode, by delta: Point) {
        for node in descendants[group] ?? [] {
            node.bounds = node.bounds.translated(by: delta)
            node.groupContentBounds = node.groupContentBounds?.translated(by: delta)
            node.groupHeaderBounds = node.groupHeaderBounds?.translated(by: delta)
        }
        for owner in [group] + (descendants[group] ?? []).filter(\.isGroup) {
            for edge in ownedEdges[owner] ?? [] {
                edge.path = edge.path.map { $0 + delta }; edge.labelBounds = edge.labelBounds.translated(by: delta)
            }
        }
    }
}

extension GroupLayoutEngine {
    /// A bounded, deterministic coordinate descent after bottom-up fitting. Parent cores only
    /// see frame centres; here real descendant endpoints can improve lateral alignment without
    /// changing frame size, sibling order/spacing or a moved subtree's internal geometry.
    func refineIncomingEdges(excluding failures: Set<LayoutEdge>) throws {
        guard groups.count > 1 else { return }
        let boundary = graph.edges.filter { containers[$0.source] !== containers[$0.target] }
        guard !boundary.isEmpty else { return }
        func length(_ edges: [LayoutEdge]) -> Float {
            edges.reduce(0) { sum, edge in
                sum + zip(edge.path, edge.path.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
            }
        }
        func contains(_ outer: Rect, _ inner: Rect) -> Bool {
            inner.left >= outer.left - 1e-5 && inner.right <= outer.right + 1e-5 &&
            inner.top >= outer.top - 1e-5 && inner.bottom <= outer.bottom + 1e-5
        }
        func obstacles() -> LayoutGraph {
            let routing = subgraph(graph, nodes: graph.nodes)
            for group in groups where group !== graph.root {
                if let header = group.groupHeaderBounds, header.width > 0, header.height > 0 {
                    let node = LayoutNode(id: "header:" + group.id, width: header.width, height: header.height)
                    node.bounds = header; routing.addNode(node)
                }
            }
            return routing
        }
        let initialScene = ObstaclePolyline.Scene(obstacles().nodes)
        // Existing fallback/custom paths must not prevent unrelated improvements, but a move
        // may not obstruct any previously clear path, including paths it does not reroute.
        var clearEdges = graph.edges.filter { $0.path.count >= 2 && initialScene.clear($0.path, $0) }
        var anyChanged = false
        for _ in 0..<2 {
            var changed = false
            for group in groups.reversed() {
                for node in group.children where group !== graph.root || node.isGroup {
                    try Task.checkCancellation()
                    let moved = [node] + (descendants[node] ?? []), members = Set(moved)
                    var ancestor: LayoutNode? = node, fixed = moved.contains { $0.metadata[GraphMetadataKeys.fixed] as? Bool == true }
                    while let current = ancestor {
                        fixed = fixed || current.metadata[GraphMetadataKeys.fixed] as? Bool == true
                        ancestor = containers[current]
                    }
                    guard !fixed else { continue }
                    let incoming = boundary.filter { members.contains($0.target) && !members.contains($0.source) }
                    guard !incoming.isEmpty else { continue }
                    let incident = graph.edges.filter { members.contains($0.source) || members.contains($0.target) }
                    let crossing = incident.filter { members.contains($0.source) != members.contains($0.target) }
                    guard incident.allSatisfy({ !failures.contains($0) && $0.path.count >= 2 }) else { continue }
                    let offsets = incoming.map { $0.source.center - $0.target.center }
                    let mean = offsets.reduce(.zero) { $0 + $1 / Float(offsets.count) }
                    // Use absolute flow so opposing inputs do not cancel the primary axis.
                    let horizontal = offsets.reduce(0) { $0 + abs($1.y) } >= offsets.reduce(0) { $0 + abs($1.x) }
                    var low = -Float.infinity, high = Float.infinity
                    if group !== graph.root, let content = group.groupContentBounds {
                        low = horizontal ? content.left - node.bounds.left : content.top - node.bounds.top
                        high = horizontal ? content.right - node.bounds.right : content.bottom - node.bounds.bottom
                    }
                    // Retain the existing separation from siblings sharing the same strip.
                    for sibling in group.children where sibling !== node {
                        let a = node.bounds, b = sibling.bounds
                        if horizontal, a.top < b.bottom, b.top < a.bottom {
                            if b.right <= a.left { low = max(low, 0) }
                            else if a.right <= b.left { high = min(high, 0) }
                            else { low = 0; high = 0 }
                        } else if !horizontal, a.left < b.right, b.left < a.right {
                            if b.bottom <= a.top { low = max(low, 0) }
                            else if a.bottom <= b.top { high = min(high, 0) }
                            else { low = 0; high = 0 }
                        }
                    }
                    guard low <= high else { continue }
                    let shift = min(high, max(low, horizontal ? mean.x : mean.y))
                    guard shift.isFinite, abs(shift) > 1e-5 else { continue }
                    let nodeState = moved.map { ($0, $0.bounds, $0.groupContentBounds, $0.groupHeaderBounds) }
                    let edgeState = incident.map { ($0, $0.path, $0.labelBounds) }
                    let beforeIncoming = length(incoming), beforeTotal = length(crossing)
                    func restore() {
                        for (n, bounds, content, header) in nodeState {
                            n.bounds = bounds; n.groupContentBounds = content; n.groupHeaderBounds = header
                        }
                        for (edge, path, label) in edgeState { edge.path = path; edge.labelBounds = label }
                    }
                    for fraction: Float in [1.0, 0.5] {
                        let delta = horizontal ? Point(x: shift * fraction) : Point(y: shift * fraction)
                        for (n, bounds, content, header) in nodeState {
                            n.bounds = bounds.translated(by: delta)
                            n.groupContentBounds = content?.translated(by: delta)
                            n.groupHeaderBounds = header?.translated(by: delta)
                        }
                        guard moved.allSatisfy({ [ $0.bounds.left, $0.bounds.right, $0.bounds.top, $0.bounds.bottom ].allSatisfy(\.isFinite) }) else {
                            restore(); continue
                        }
                        for (edge, path, label) in edgeState where members.contains(edge.source) && members.contains(edge.target) {
                            edge.path = path.map { $0 + delta }; edge.labelBounds = label.translated(by: delta)
                        }
                        let routing = obstacles(); routing.edges = crossing
                        let router = PolylineEdgeRouter(); router.routeEdges(routing)
                        try Task.checkCancellation()
                        centerLabels(on: crossing)
                        let scene = ObstaclePolyline.Scene(routing.nodes)
                        let fits = groups.filter { $0 !== graph.root }.allSatisfy { owner in
                            guard let content = owner.groupContentBounds else { return false }
                            return owner.children.allSatisfy { contains(content, $0.bounds) } &&
                                (ownedEdges[owner] ?? []).allSatisfy { edge in
                                    edge.path.allSatisfy { contains(content, Rect(x: $0.x, y: $0.y)) } &&
                                    (edge.labelBounds.width <= 0 || edge.labelBounds.height <= 0 || contains(content, edge.labelBounds))
                                }
                        }
                        if router.unroutableEdges.isEmpty, fits,
                           length(incoming) < beforeIncoming - 1e-5, length(crossing) <= beforeTotal + 1e-5,
                           crossing.allSatisfy({ scene.clear($0.path, $0) }),
                           clearEdges.allSatisfy({ scene.clear($0.path, $0) }) {
                            clearEdges = graph.edges.filter { $0.path.count >= 2 && scene.clear($0.path, $0) }
                            changed = true; anyChanged = true
                            break
                        }
                        restore()
                    }
                }
            }
            if !changed { break }
        }
        if anyChanged && boundary.count > 1 {
            let scene = ObstaclePolyline.Scene(obstacles().nodes)
            let saved = boundary.map { ($0, $0.path, $0.labelBounds, scene.clear($0.path, $0)) }
            let separator = EdgeSeparator(); separator.spacing = 6
            separator.separate(boundary, scene)
            for (edge, oldPath, oldLabel, wasClear) in saved where edge.path != oldPath {
                let owners = groups.filter { $0 !== graph.root && (ownedEdges[$0] ?? []).contains(edge) }
                for owner in owners {
                    guard let c = owner.groupContentBounds else { continue }
                    edge.path = edge.path.map { Point(x: min(max($0.x, c.left), c.right), y: min(max($0.y, c.top), c.bottom)) }
                }
                centerLabels(on: [edge])
                let clearOK = !wasClear || scene.clear(edge.path, edge)
                let ownerOK = owners.allSatisfy { owner in
                    guard let content = owner.groupContentBounds else { return false }
                    return edge.path.allSatisfy { contains(content, Rect(x: $0.x, y: $0.y)) } &&
                        (edge.labelBounds.width <= 0 || edge.labelBounds.height <= 0 || contains(content, edge.labelBounds))
                }
                if !clearOK || !ownerOK {
                    edge.path = oldPath; edge.labelBounds = oldLabel
                }
            }
        }
    }
}
