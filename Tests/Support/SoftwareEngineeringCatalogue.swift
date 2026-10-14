import Foundation
import SwiftGraph

private final class LoopAwareLayout: LayoutAlgorithm {
    let base: any LayoutAlgorithm
    init(_ base: any LayoutAlgorithm) { self.base = base }
    func applyLayout(_ graph: LayoutGraph) throws {
        try base.applyLayout(graph)
        SelfLoopRouter().routeEdges(graph)
    }
}

private final class LoopAwareAsyncLayout: LayoutExecutionReporting {
    let base: any LayoutExecutionReporting
    let backend: LayoutBackend
    let executor: LayoutExecutor
    private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []
    init(_ base: any LayoutExecutionReporting, backend: LayoutBackend, executor: LayoutExecutor) {
        self.base = base; self.backend = backend; self.executor = executor
    }
    func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastExecutionMetrics = []
        try await base.applyLayoutAsync(graph)
        let loops = RoutingLayoutOperation(.selfLoops, backend: backend, executor: executor)
        try await loops.applyLayoutAsync(graph)
        lastExecutionMetrics = base.lastExecutionMetrics + loops.lastExecutionMetrics
    }
}

enum SEBackendContext {
    @TaskLocal static var active: (backend: LayoutBackend, executor: LayoutExecutor)?
    final class Recorder: @unchecked Sendable {
        var metrics: [LayoutExecutionMetrics] = []
    }
    @TaskLocal static var recorder: Recorder?
}

extension VisualCatalogue {
    static func softwareEngineeringCases() -> [VisualCase] {
        architectureCases() + dependencyCases() + callGraphCases() + stateMachineCases() + pipelineAndDataFlowCases() + schemaAndConstrainedCases()
    }

    static func runSoftwareEngineering(_ item: VisualCase, backend: LayoutBackend, executor: LayoutExecutor) async throws -> (VisualDrawing, [LayoutExecutionMetrics]) {
        let recorder = SEBackendContext.Recorder()
        let drawing = try await SEBackendContext.$active.withValue((backend, executor)) {
            try await SEBackendContext.$recorder.withValue(recorder) {
                try await item.run()
            }
        }
        return (drawing, recorder.metrics)
    }

    @discardableResult
    private static func addLeaf(_ graph: LayoutGraph, _ id: String, name: String? = nil, width: Double = 104, height: Double = 36, parent: LayoutNode? = nil) throws -> LayoutNode {
        let label = name ?? id
        let minWidth = (Double(label.count) * 7.0 + 14).rounded(.up)
        let node = LayoutNode(id: id, width: max(width, minWidth), height: height)
        node.name = label
        try graph.addNode(node, to: parent)
        return node
    }

    @discardableResult
    private static func addFrame(_ graph: LayoutGraph, _ id: String, title: String? = nil, parent: LayoutNode? = nil, headerWidth: Double = 180, minSize: Size = Size(), padding: LayoutInsets = LayoutInsets(20)) throws -> LayoutNode {
        let group = try graph.addGroup(id: id, parent: parent, frame: GroupFrameOptions(padding: padding, headerSize: Size(width: headerWidth, height: 26), minimumSize: minSize))
        group.name = title ?? id
        return group
    }

    @discardableResult
    private static func link(_ graph: LayoutGraph, _ s: LayoutNode, _ t: LayoutNode, label: String? = nil, labelSize: Size = Size(width: 68, height: 18), sourcePort: PortConstraint = .none, targetPort: PortConstraint = .none) -> LayoutEdge {
        let edge = LayoutEdge(source: s, target: t, data: label)
        if label != nil { edge.labelBounds = Rect(width: labelSize.width, height: labelSize.height) }
        edge.sourcePort = sourcePort; edge.targetPort = targetPort
        graph.addEdge(edge)
        return edge
    }

    // MARK: - 1. Cloud & Microservices Architecture (Framed Nested Groups)

    private static func architectureCases() -> [VisualCase] {
        [
            VisualCase(
                id: "se-arch-microservices-small",
                family: "engineering",
                title: "SE Architecture · Small microservices & nested frames",
                configuration: ["domain": "architecture", "scale": "small", "pipeline": "RecursiveGroupLayout (mixed selectors) → clip"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, framedGroups: true),
                smoke: true
            ) {
                let g = LayoutGraph()
                let vpc = try addFrame(g, "vpc", title: "Production VPC · us-east-1", headerWidth: 260)
                let edgeTier = try addFrame(g, "edge-tier", title: "Edge & Ingress Tier", parent: vpc, headerWidth: 200)
                let coreTier = try addFrame(g, "core-tier", title: "Core Domain Services", parent: vpc, headerWidth: 220)
                let dataTier = try addFrame(g, "data-tier", title: "Stateful Data Layer", parent: vpc, headerWidth: 200)

                let cdn = try addLeaf(g, "cdn", name: "CloudFront CDN", width: 120, height: 36)
                let waf = try addLeaf(g, "waf", name: "WAF Firewall", width: 110, height: 36, parent: edgeTier)
                let gw = try addLeaf(g, "api-gw", name: "API Gateway", width: 120, height: 40, parent: edgeTier)
                let auth = try addLeaf(g, "auth-svc", name: "Auth Service", width: 108, height: 36, parent: edgeTier)

                let orders = try addLeaf(g, "order-svc", name: "Order Service", width: 112, height: 38, parent: coreTier)
                let billing = try addLeaf(g, "billing-svc", name: "Billing Service", width: 112, height: 38, parent: coreTier)
                let inventory = try addLeaf(g, "inventory-svc", name: "Inventory Svc", width: 112, height: 38, parent: coreTier)
                let bus = try addLeaf(g, "event-bus", name: "Kafka Event Bus", width: 130, height: 38, parent: coreTier)

                let pgPrimary = try addLeaf(g, "pg-primary", name: "Postgres Primary", width: 124, height: 38, parent: dataTier)
                let pgReplica = try addLeaf(g, "pg-replica", name: "Postgres Replica", width: 124, height: 38, parent: dataTier)
                let redis = try addLeaf(g, "redis-cache", name: "Redis Cluster", width: 110, height: 36, parent: dataTier)
                let stripe = try addLeaf(g, "stripe-ext", name: "Stripe Webhook API", width: 136, height: 38)

                link(g, cdn, waf); link(g, waf, gw); link(g, gw, auth); link(g, auth, gw)
                link(g, gw, orders); link(g, gw, billing); link(g, gw, inventory)
                link(g, orders, billing); link(g, orders, bus); link(g, billing, bus); link(g, bus, inventory)
                link(g, orders, pgPrimary); link(g, inventory, pgReplica); link(g, auth, redis)
                link(g, pgPrimary, pgReplica); link(g, billing, stripe); link(g, gw, gw)

                let fallbacks: [Int]
                if let ctx = SEBackendContext.active {
                    let defaultCore = LoopAwareAsyncLayout(HierarchicalLayoutOperation(backend: ctx.backend, executor: ctx.executor), backend: ctx.backend, executor: ctx.executor)
                    let layout = RecursiveGroupLayoutOperation(defaultCore, backend: ctx.backend, executor: ctx.executor)
                    layout.groupLayoutSelector = { group in
                        if group === coreTier {
                            var c = BasicLayoutConfiguration(style: .circular); c.radius = 120
                            return LoopAwareAsyncLayout(BasicLayoutOperation(style: .circular, backend: ctx.backend, executor: ctx.executor, configuration: c), backend: ctx.backend, executor: ctx.executor)
                        }
                        if group === dataTier {
                            return LoopAwareAsyncLayout(TreeLayoutOperation(style: .tree, backend: ctx.backend, executor: ctx.executor), backend: ctx.backend, executor: ctx.executor)
                        }
                        return LoopAwareAsyncLayout(HierarchicalLayoutOperation(backend: ctx.backend, executor: ctx.executor), backend: ctx.backend, executor: ctx.executor)
                    }
                    try await layout.applyLayoutAsync(g)
                    let clip = RoutingLayoutOperation(.endpointClipping, backend: ctx.backend, executor: ctx.executor)
                    try await clip.applyLayoutAsync(g)
                    PortDistributor().routeEdges(g)
                    SEBackendContext.recorder?.metrics += layout.lastExecutionMetrics + clip.lastExecutionMetrics
                    fallbacks = layout.unroutableEdges.compactMap { g.edges.firstIndex(of: $0) }
                } else {
                    let layout = RecursiveGroupLayout(LoopAwareLayout(HierarchicalLayoutAlgorithm()))
                    layout.groupLayoutSelector = { group in
                        if group === coreTier {
                            let c = CircularLayoutAlgorithm(); c.radius = 120; return LoopAwareLayout(c)
                        }
                        if group === dataTier { return LoopAwareLayout(TreeLayoutAlgorithm()) }
                        return LoopAwareLayout(HierarchicalLayoutAlgorithm())
                    }
                    try layout.applyLayout(g)
                    EdgeEndpointClipper.clipToNodeBounds(g)
                    PortDistributor().routeEdges(g)
                    fallbacks = layout.unroutableEdges.compactMap { g.edges.firstIndex(of: $0) }
                }
                return VisualDrawing(
                    graph: g,
                    fallbackEdges: fallbacks,
                    reportedMetrics: ["scaleTier": 1, "groupCount": 4, "leafCount": 12],
                    notes: ["Small cloud architecture with 2-level nested frames, mixed layout selectors, reciprocal auth call, and self-loop health check."]
                )
            },

            VisualCase(
                id: "se-arch-microservices-medium",
                family: "engineering",
                title: "SE Architecture · Medium multi-AZ cloud mesh",
                configuration: ["domain": "architecture", "scale": "medium", "pipeline": "RecursiveGroupLayout (3-level Multi-AZ) → clip"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, framedGroups: true)
            ) {
                let g = LayoutGraph()
                let cloud = try addFrame(g, "cloud-mesh", title: "Enterprise Cloud Mesh · Multi-AZ Production", headerWidth: 340)
                let azA = try addFrame(g, "az-a", title: "Availability Zone A (us-east-1a)", parent: cloud, headerWidth: 260)
                let azB = try addFrame(g, "az-b", title: "Availability Zone B (us-east-1b)", parent: cloud, headerWidth: 260)
                let obs = try addFrame(g, "observability", title: "Observability & Control Plane", parent: cloud, headerWidth: 250)
                let drStandby = try addFrame(g, "dr-standby", title: "Cold Standby Vault · Reserved Capacity", parent: cloud, headerWidth: 260, minSize: Size(width: 280, height: 110))
                _ = drStandby

                let subAApp = try addFrame(g, "az-a-app", title: "AZ-A Compute Subnet", parent: azA, headerWidth: 200)
                let subAData = try addFrame(g, "az-a-data", title: "AZ-A Storage Subnet", parent: azA, headerWidth: 200)
                let subBApp = try addFrame(g, "az-b-app", title: "AZ-B Compute Subnet", parent: azB, headerWidth: 200)
                let subBData = try addFrame(g, "az-b-data", title: "AZ-B Storage Subnet", parent: azB, headerWidth: 200)

                let dns = try addLeaf(g, "route53", name: "Route53 Global DNS", width: 140, height: 38)
                let albA = try addLeaf(g, "alb-a", name: "ALB Ingress A", width: 118, height: 36, parent: azA)
                let albB = try addLeaf(g, "alb-b", name: "ALB Ingress B", width: 118, height: 36, parent: azB)
                link(g, dns, albA); link(g, dns, albB)

                let serviceNames = ["Gateway", "Identity", "Catalog", "Cart", "Checkout", "Ledger", "Shipping", "Search", "Recommend", "Notify"]
                var aServices: [LayoutNode] = [], bServices: [LayoutNode] = []
                for (i, sName) in serviceNames.enumerated() {
                    let na = try addLeaf(g, "aza-\(sName.lowercased())", name: "\(sName)-A", width: 96 + Double(i % 3) * 12, height: 34, parent: subAApp)
                    let nb = try addLeaf(g, "azb-\(sName.lowercased())", name: "\(sName)-B", width: 96 + Double(i % 3) * 12, height: 34, parent: subBApp)
                    aServices.append(na); bServices.append(nb)
                }
                for i in 0..<3 {
                    link(g, albA, aServices[i]); link(g, albB, bServices[i])
                }
                for i in 0..<(serviceNames.count - 1) {
                    link(g, aServices[i], aServices[i + 1])
                    link(g, bServices[i], bServices[i + 1])
                    if i + 2 < serviceNames.count && i % 2 == 0 {
                        link(g, aServices[i], aServices[i + 2])
                        link(g, bServices[i], bServices[i + 2])
                    }
                }

                var aStores: [LayoutNode] = [], bStores: [LayoutNode] = []
                for (i, dbName) in ["Aurora-Primary", "Redis-A", "Kafka-Broker-1", "OpenSearch-A", "S3-Gateway-A"].enumerated() {
                    let da = try addLeaf(g, "aza-db-\(i)", name: dbName, width: 120, height: 36, parent: subAData)
                    let db = try addLeaf(g, "azb-db-\(i)", name: dbName.replacingOccurrences(of: "Primary", with: "Replica").replacingOccurrences(of: "-A", with: "-B").replacingOccurrences(of: "-1", with: "-2"), width: 120, height: 36, parent: subBData)
                    aStores.append(da); bStores.append(db)
                    link(g, da, db) // Cross-AZ replication
                    link(g, aServices[i * 2], da); link(g, aServices[i * 2 + 1], da)
                    link(g, bServices[i * 2], db); link(g, bServices[i * 2 + 1], db)
                }

                var obsNodes: [LayoutNode] = []
                for (i, oName) in ["OTel-Collector", "Prometheus", "Jaeger-Query", "Grafana-UI", "AlertManager", "PagerDuty-Hook", "Audit-Sink"].enumerated() {
                    let n = try addLeaf(g, "obs-\(i)", name: oName, width: 116, height: 34, parent: obs)
                    obsNodes.append(n)
                    if i > 0 { link(g, obsNodes[(i - 1) / 2], n) }
                }
                link(g, aServices[0], obsNodes[0]); link(g, bServices[0], obsNodes[0])
                link(g, aStores[2], obsNodes[0]); link(g, bStores[2], obsNodes[0])

                let fallbacks: [Int]
                if let ctx = SEBackendContext.active {
                    let layout = RecursiveGroupLayoutOperation(HierarchicalLayoutOperation(backend: ctx.backend, executor: ctx.executor), backend: ctx.backend, executor: ctx.executor)
                    layout.optimizeIncomingEdges = true
                    try await layout.applyLayoutAsync(g)
                    let clip = RoutingLayoutOperation(.endpointClipping, backend: ctx.backend, executor: ctx.executor)
                    try await clip.applyLayoutAsync(g)
                    PortDistributor().routeEdges(g)
                    SEBackendContext.recorder?.metrics += layout.lastExecutionMetrics + clip.lastExecutionMetrics
                    fallbacks = layout.unroutableEdges.compactMap { g.edges.firstIndex(of: $0) }
                } else {
                    let layout = RecursiveGroupLayout(HierarchicalLayoutAlgorithm())
                    layout.optimizeIncomingEdges = true
                    try layout.applyLayout(g)
                    EdgeEndpointClipper.clipToNodeBounds(g)
                    PortDistributor().routeEdges(g)
                    fallbacks = layout.unroutableEdges.compactMap { g.edges.firstIndex(of: $0) }
                }
                return VisualDrawing(
                    graph: g,
                    fallbackEdges: fallbacks,
                    reportedMetrics: ["scaleTier": 2, "groupCount": 9, "leafCount": Double(g.nodes.filter { !$0.isGroup }.count)],
                    notes: ["Medium 3-level Multi-AZ cloud architecture with cross-AZ replication links, empty standby frame with minimum bounds, and incoming-edge alignment."]
                )
            },

            VisualCase(
                id: "se-arch-microservices-large",
                family: "engineering",
                title: "SE Architecture · Large 5-domain enterprise platform",
                configuration: ["domain": "architecture", "scale": "large", "pipeline": "RecursiveGroupLayout (5 domains, 16 frames) → clip"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, framedGroups: true)
            ) {
                let g = LayoutGraph()
                let domains = ["Identity", "Commerce", "Fulfillment", "Analytics", "Platform"]
                var domainFrames: [LayoutNode] = []
                var entryNodes: [LayoutNode] = []
                var exitNodes: [LayoutNode] = []

                let edgeIngress = try addLeaf(g, "global-edge", name: "Global Anycast Edge", width: 150, height: 42)
                let meshControl = try addLeaf(g, "mesh-control", name: "Istio Service Mesh Control", width: 160, height: 42)
                link(g, edgeIngress, meshControl)

                for (dIdx, domain) in domains.enumerated() {
                    let dFrame = try addFrame(g, "dom-\(dIdx)", title: "\(domain) Domain Boundary", headerWidth: 240)
                    domainFrames.append(dFrame)
                    let apiFrame = try addFrame(g, "dom-\(dIdx)-api", title: "\(domain) API & BFF", parent: dFrame, headerWidth: 190)
                    let workerFrame = try addFrame(g, "dom-\(dIdx)-wrk", title: "\(domain) Domain Workers", parent: dFrame, headerWidth: 190)
                    let storeFrame = try addFrame(g, "dom-\(dIdx)-db", title: "\(domain) Persistence", parent: dFrame, headerWidth: 190)

                    var apiNodes: [LayoutNode] = []
                    for i in 0..<8 {
                        let n = try addLeaf(g, "d\(dIdx)-api-\(i)", name: "\(domain.prefix(4))-API-\(i)", width: 92 + Double(i % 3) * 10, height: 32, parent: apiFrame)
                        apiNodes.append(n)
                        if i > 0 { link(g, apiNodes[(i - 1) / 2], n) }
                    }
                    var workerNodes: [LayoutNode] = []
                    for i in 0..<12 {
                        let n = try addLeaf(g, "d\(dIdx)-wrk-\(i)", name: "\(domain.prefix(4))-Wrk-\(i)", width: 90 + Double(i % 2) * 14, height: 32, parent: workerFrame)
                        workerNodes.append(n)
                        if i > 0 { link(g, workerNodes[(i - 1) / 3], n) }
                        if i > 3 && i % 4 == 0 { link(g, workerNodes[i - 2], n) }
                    }
                    var storeNodes: [LayoutNode] = []
                    for i in 0..<8 {
                        let n = try addLeaf(g, "d\(dIdx)-db-\(i)", name: "\(domain.prefix(4))-Store-\(i)", width: 100, height: 34, parent: storeFrame)
                        storeNodes.append(n)
                        if i > 0 { link(g, storeNodes[(i - 1) / 3], n) }
                    }

                    link(g, apiNodes[0], workerNodes[0])
                    link(g, apiNodes[1], workerNodes[1])
                    link(g, workerNodes[0], storeNodes[0])
                    link(g, workerNodes[2], storeNodes[1])
                    entryNodes.append(apiNodes[0])
                    exitNodes.append(storeNodes[0])
                }

                for dIdx in domains.indices {
                    link(g, edgeIngress, entryNodes[dIdx])
                }
                // 2-tier cross-domain event flows (Identity/Platform feed Commerce/Fulfillment/Analytics)
                link(g, exitNodes[0], entryNodes[1])
                link(g, exitNodes[0], entryNodes[2])
                link(g, exitNodes[1], entryNodes[3])
                link(g, exitNodes[4], entryNodes[3])
                link(g, meshControl, entryNodes[0])
                link(g, meshControl, entryNodes[4])

                let fallbacks: [Int]
                if let ctx = SEBackendContext.active {
                    let layout = RecursiveGroupLayoutOperation(HierarchicalLayoutOperation(backend: ctx.backend, executor: ctx.executor), backend: ctx.backend, executor: ctx.executor)
                    layout.optimizeIncomingEdges = false
                    try await layout.applyLayoutAsync(g)
                    let clip = RoutingLayoutOperation(.endpointClipping, backend: ctx.backend, executor: ctx.executor)
                    try await clip.applyLayoutAsync(g)
                    PortDistributor().routeEdges(g)
                    SEBackendContext.recorder?.metrics += layout.lastExecutionMetrics + clip.lastExecutionMetrics
                    fallbacks = layout.unroutableEdges.compactMap { g.edges.firstIndex(of: $0) }
                } else {
                    let layout = RecursiveGroupLayout(HierarchicalLayoutAlgorithm())
                    layout.optimizeIncomingEdges = false
                    try layout.applyLayout(g)
                    EdgeEndpointClipper.clipToNodeBounds(g)
                    PortDistributor().routeEdges(g)
                    fallbacks = layout.unroutableEdges.compactMap { g.edges.firstIndex(of: $0) }
                }
                return VisualDrawing(
                    graph: g,
                    fallbackEdges: fallbacks,
                    reportedMetrics: ["scaleTier": 3, "groupCount": Double(g.nodes.filter(\.isGroup).count), "leafCount": Double(g.nodes.filter { !$0.isGroup }.count)],
                    notes: ["Large 5-domain enterprise platform architecture (~160 leaves + 15 nested frames) testing hierarchical frame fitting and cross-domain obstacle routing."]
                )
            }
        ]
    }

    // MARK: - 2. Package, Module & Class Dependency Graphs

    private static func dependencyCases() -> [VisualCase] {
        [
            VisualCase(
                id: "se-deps-module-small",
                family: "engineering",
                title: "SE Dependencies · Small diamond & cyclic modules",
                configuration: ["domain": "dependencies", "scale": "small", "pipeline": "DirectedLayoutOperation (.fresh)"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, orthogonal: true),
                smoke: true
            ) {
                let g = LayoutGraph()
                let specs: [(String, Double, Double)] = [
                    ("AppTarget", 110, 38), ("FeatureAuth", 114, 36), ("FeatureFeed", 114, 36), ("FeatureSearch", 120, 36),
                    ("UIComponents", 122, 36), ("DomainCore", 116, 38), ("LegacyBridge", 118, 36), ("NetworkClient", 120, 36),
                    ("CacheStore", 108, 34), ("AnalyticsSDK", 116, 34), ("CoreModels", 108, 36), ("LoggerCore", 106, 36),
                    ("CryptoUtils", 108, 34), ("ConfigService", 116, 34), ("PluginHost", 106, 36), ("PluginAPI", 102, 34)
                ]
                for (id, w, h) in specs { try addLeaf(g, id, width: w, height: h) }
                let byID = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0) })
                let pairs: [(String, String, Double)] = [
                    ("AppTarget", "FeatureAuth", 2.5), ("AppTarget", "FeatureFeed", 2.5), ("AppTarget", "FeatureSearch", 2.0),
                    ("FeatureAuth", "UIComponents", 1.5), ("FeatureFeed", "UIComponents", 1.5), ("FeatureSearch", "UIComponents", 1.5),
                    ("FeatureAuth", "DomainCore", 2.0), ("FeatureFeed", "DomainCore", 2.0), ("FeatureSearch", "DomainCore", 2.0),
                    ("DomainCore", "LegacyBridge", 2.0), ("LegacyBridge", "DomainCore", 2.0), // Reciprocal cycle
                    ("DomainCore", "NetworkClient", 1.5), ("DomainCore", "CacheStore", 1.5), ("LegacyBridge", "CacheStore", 1.5),
                    ("NetworkClient", "CoreModels", 1.5), ("CacheStore", "CoreModels", 1.5), ("UIComponents", "CoreModels", 1.5),
                    ("NetworkClient", "CryptoUtils", 1.5), ("FeatureAuth", "CryptoUtils", 1.5),
                    ("DomainCore", "ConfigService", 1.5), ("NetworkClient", "ConfigService", 1.5),
                    ("AppTarget", "AnalyticsSDK", 1.5), ("FeatureFeed", "AnalyticsSDK", 1.5),
                    ("FeatureAuth", "LoggerCore", 1.2), ("FeatureFeed", "LoggerCore", 1.2), ("DomainCore", "LoggerCore", 1.2),
                    ("NetworkClient", "LoggerCore", 1.2), ("CacheStore", "LoggerCore", 1.2), ("AnalyticsSDK", "LoggerCore", 1.2),
                    ("PluginHost", "PluginAPI", 1.8), ("PluginAPI", "CoreModels", 1.5)
                ]
                var widths: [Double] = []
                for (s, t, w) in pairs { link(g, byID[s]!, byID[t]!); widths.append(w) }
                var config = DirectedLayoutConfiguration(); config.edgeWidths = widths
                let diag: DirectedLayoutDiagnostics
                if let ctx = SEBackendContext.active {
                    let op = DirectedLayoutAsyncOperation(backend: ctx.backend, executor: ctx.executor, configuration: config)
                    try await op.applyLayoutAsync(g)
                    SEBackendContext.recorder?.metrics += op.lastExecutionMetrics
                    diag = op.lastDiagnostics!
                } else {
                    diag = try DirectedLayoutOperation(configuration: config).apply(g)
                }
                return VisualDrawing(
                    graph: g,
                    edgeWidths: widths,
                    reportedMetrics: ["scaleTier": 1, "crossings": Double(diag.crossings), "bends": Double(diag.bends), "feedbackEdges": Double(diag.feedbackEdgeIndices.count)],
                    notes: ["Small SwiftPM-style module dependency graph with diamond dependencies, LegacyBridge <-> DomainCore cycle, and high fan-in LoggerCore hub."]
                )
            },

            VisualCase(
                id: "se-deps-class-hierarchy-medium",
                family: "engineering",
                title: "SE Dependencies · Medium OOP class hierarchy & god-object hub",
                configuration: ["domain": "dependencies", "scale": "medium", "pipeline": "DirectedLayoutOperation (.fresh, port-aware capacity)"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, orthogonal: true)
            ) {
                let g = LayoutGraph()
                let god = try addLeaf(g, "ServiceLocator", name: "ServiceLocator (God Hub)", width: 150, height: 42)
                let baseCtrl = try addLeaf(g, "BaseController", width: 128, height: 36)
                let baseRepo = try addLeaf(g, "BaseRepository", width: 128, height: 36)
                let baseEntity = try addLeaf(g, "AuditableEntity", width: 128, height: 36)

                var controllers: [LayoutNode] = [], services: [LayoutNode] = [], repos: [LayoutNode] = [], entities: [LayoutNode] = []
                let domains = ["User", "Account", "Order", "Invoice", "Payment", "Shipment", "Catalog", "Inventory", "Review", "Coupon", "Notification", "Audit"]
                for d in domains {
                    let c = try addLeaf(g, "\(d)Controller", width: 122, height: 34)
                    let s = try addLeaf(g, "\(d)Service", width: 114, height: 34)
                    let r = try addLeaf(g, "\(d)Repository", width: 124, height: 34)
                    let e = try addLeaf(g, "\(d)Entity", width: 108, height: 32)
                    controllers.append(c); services.append(s); repos.append(r); entities.append(e)
                    link(g, c, baseCtrl); link(g, r, baseRepo); link(g, e, baseEntity)
                    link(g, c, s); link(g, s, r); link(g, r, e)
                    link(g, s, god) // 12 services depend on the god object
                }
                for i in 0..<6 { link(g, controllers[i * 2], god) } // 6 controllers also directly query ServiceLocator (18 total incoming to god)
                for i in 0..<(domains.count - 1) where i % 2 == 0 {
                    link(g, services[i], services[i + 1])
                    link(g, entities[i], entities[i + 1])
                }
                // Two standalone utility mini-clusters
                let u1 = try addLeaf(g, "DateFormatterPool", width: 132, height: 34)
                let u2 = try addLeaf(g, "LocaleProvider", width: 118, height: 34)
                let u3 = try addLeaf(g, "CurrencyMath", width: 114, height: 34)
                let u4 = try addLeaf(g, "DecimalRounding", width: 122, height: 34)
                link(g, u1, u2); link(g, u3, u4)

                var config = DirectedLayoutConfiguration(); config.candidateCount = 2
                let diag: DirectedLayoutDiagnostics
                if let ctx = SEBackendContext.active {
                    let op = DirectedLayoutAsyncOperation(backend: ctx.backend, executor: ctx.executor, configuration: config)
                    try await op.applyLayoutAsync(g)
                    SEBackendContext.recorder?.metrics += op.lastExecutionMetrics
                    diag = op.lastDiagnostics!
                } else {
                    diag = try DirectedLayoutOperation(configuration: config).apply(g)
                }
                return VisualDrawing(
                    graph: g,
                    reportedMetrics: ["scaleTier": 2, "godNodeHeight": god.height, "crossings": Double(diag.crossings), "bends": Double(diag.bends)],
                    notes: ["Medium 56-node OOP class diagram where 18 classes reference ServiceLocator, testing dynamic port-capacity expansion and multi-component packing."]
                )
            },

            VisualCase(
                id: "se-deps-monolith-large",
                family: "engineering",
                title: "SE Dependencies · Large 8-layer modular monolith (200 nodes)",
                configuration: ["domain": "dependencies", "scale": "large", "pipeline": "Hierarchical → RemoveOverlaps → Polyline → EdgeSeparator → SelfLoop → Clip → PortDistributor"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true)
            ) {
                let g = LayoutGraph()
                let layerNames = ["Views", "Presenters", "UseCases", "Domain", "Gateways", "Repositories", "Persistence", "Foundation"]
                var layers: [[LayoutNode]] = []
                for (lIdx, lName) in layerNames.enumerated() {
                    var row: [LayoutNode] = []
                    for i in 0..<25 {
                        let n = try addLeaf(g, "L\(lIdx)-\(lName)-\(i)", name: "\(lName.prefix(4))Mod\(i)", width: 88 + Double((lIdx + i) % 3) * 14, height: 32)
                        row.append(n)
                    }
                    layers.append(row)
                }
                for l in 0..<(layers.count - 1) {
                    for i in 0..<25 {
                        link(g, layers[l][i], layers[l + 1][i])
                        link(g, layers[l][i], layers[l + 1][(i + 3) % 25])
                        // Architectural violation skip-edges (every 5th module jumps 2-3 layers down)
                        if i % 5 == 0 && l + 2 < layers.count {
                            link(g, layers[l][i], layers[l + 2][(i + 1) % 25])
                        }
                    }
                }
                // Legacy cyclic couplings and self-dependencies
                for i in stride(from: 0, to: 25, by: 6) {
                    link(g, layers[3][i], layers[2][i])
                    link(g, layers[5][i], layers[5][i])
                }
                if let ctx = SEBackendContext.active {
                    let builder = LayoutBuilder.create(g)
                        .useHierarchical(backend: ctx.backend, executor: ctx.executor) { $0.nodeSeparation = 42; $0.layerSeparation = 98; $0.maxNodesPerRank = 18 }
                        .useRemoveOverlaps(backend: ctx.backend, executor: ctx.executor)
                        .routePolyline(backend: ctx.backend, executor: ctx.executor)
                        .separateEdges(backend: ctx.backend, executor: ctx.executor)
                        .routeSelfLoops(backend: ctx.backend, executor: ctx.executor)
                        .clipEdgeEndpoints(backend: ctx.backend, executor: ctx.executor)
                        .distributePorts(backend: ctx.backend, executor: ctx.executor)
                    try await builder.applyAsync()
                    SEBackendContext.recorder?.metrics += builder.lastExecutionMetrics
                } else {
                    try await LayoutBuilder.create(g)
                        .useHierarchical { $0.nodeSeparation = 42; $0.layerSeparation = 98; $0.maxNodesPerRank = 18 }
                        .removeOverlaps()
                        .routePolyline()
                        .separateEdges()
                        .routeSelfLoops()
                        .clipEdgeEndpoints()
                        .distributePorts()
                        .applyAsync()
                }
                return VisualDrawing(
                    graph: g,
                    reportedMetrics: ["scaleTier": 3, "layerCount": 8, "nodeCount": Double(g.nodes.count), "edgeCount": Double(g.edges.count)],
                    notes: ["Large 200-node, 8-layer modular monolith with skip-layer dependencies, cyclic domain couplings, and obstacle-free separated routing."]
                )
            }
        ]
    }

    // MARK: - 3. Call Graphs & Execution Traces

    private static func callGraphCases() -> [VisualCase] {
        [
            VisualCase(
                id: "se-callgraph-recursion-small",
                family: "engineering",
                title: "SE Call Graph · Small recursive-descent parser",
                configuration: ["domain": "callgraph", "scale": "small", "pipeline": "DirectedLayoutOperation (.fresh)"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, orthogonal: true)
            ) {
                let g = LayoutGraph()
                let funcs = [
                    "parseCompilationUnit", "parseDeclaration", "parseFunctionDecl", "parseBlockStmt",
                    "parseStatement", "parseIfStmt", "parseReturnStmt", "parseExpression",
                    "parseBinaryOp", "parseUnaryOp", "parsePrimary", "lexNextToken",
                    "skipTrivia", "emitDiagnostic"
                ]
                for (i, fn) in funcs.enumerated() {
                    try addLeaf(g, fn, name: fn + "()", width: 132 + Double(i % 3) * 14, height: 34)
                }
                let byID = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0) })
                let calls: [(String, String)] = [
                    ("parseCompilationUnit", "parseDeclaration"), ("parseDeclaration", "parseFunctionDecl"),
                    ("parseFunctionDecl", "parseBlockStmt"), ("parseBlockStmt", "parseStatement"),
                    ("parseStatement", "parseIfStmt"), ("parseStatement", "parseReturnStmt"),
                    ("parseStatement", "parseExpression"), ("parseIfStmt", "parseBlockStmt"), // Mutual recursion cycle 1
                    ("parseIfStmt", "parseExpression"), ("parseReturnStmt", "parseExpression"),
                    ("parseExpression", "parseBinaryOp"), ("parseBinaryOp", "parseUnaryOp"),
                    ("parseUnaryOp", "parsePrimary"), ("parsePrimary", "parseExpression"), // Mutual recursion cycle 2
                    ("parseUnaryOp", "parseUnaryOp"), // Direct self-recursion
                    ("parseDeclaration", "lexNextToken"), ("parseStatement", "lexNextToken"),
                    ("parsePrimary", "lexNextToken"), ("lexNextToken", "skipTrivia"),
                    ("skipTrivia", "skipTrivia"), // Direct self-recursion
                    ("parseDeclaration", "emitDiagnostic"), ("parseStatement", "emitDiagnostic"),
                    ("parsePrimary", "emitDiagnostic"), ("lexNextToken", "emitDiagnostic")
                ]
                for (s, t) in calls { link(g, byID[s]!, byID[t]!) }
                let diag: DirectedLayoutDiagnostics
                if let ctx = SEBackendContext.active {
                    let op = DirectedLayoutAsyncOperation(backend: ctx.backend, executor: ctx.executor)
                    try await op.applyLayoutAsync(g)
                    SEBackendContext.recorder?.metrics += op.lastExecutionMetrics
                    diag = op.lastDiagnostics!
                } else {
                    diag = try DirectedLayoutOperation().apply(g)
                }
                return VisualDrawing(
                    graph: g,
                    reportedMetrics: ["scaleTier": 1, "feedbackEdges": Double(diag.feedbackEdgeIndices.count), "crossings": Double(diag.crossings)],
                    notes: ["Recursive-descent compiler call graph with 2 mutual-recursion cycles, 2 self-recursive functions, and diagnostic fan-in."]
                )
            },

            VisualCase(
                id: "se-callgraph-trace-medium",
                family: "engineering",
                title: "SE Call Graph · Medium PageRank-weighted request trace",
                configuration: ["domain": "callgraph", "scale": "medium", "pipeline": "PageRank importance scaling → Hierarchical → RemoveOverlaps → Polyline → Separate → SelfLoop → Clip → PortDistributor"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true)
            ) {
                let g = LayoutGraph()
                let stages: [[String]] = [
                    ["HTTP2Listener", "gRPCListener"],
                    ["TLSHandshake", "RateLimiter", "JWTVerifier", "TraceInjector"],
                    ["RouterDispatch", "GraphQLResolver", "RESTController", "WebhookHandler"],
                    ["AuthzPolicyEngine", "TenantContextLoader", "FeatureFlagEval", "RequestValidator", "IdempotencyGuard"],
                    ["OrderOrchestrator", "CartAggregator", "PricingCalculator", "TaxEngine", "InventoryReservation", "FraudScorer", "PaymentAuthorizer"],
                    ["DiscountRuleEval", "CurrencyConverter", "AddressNormalizer", "StockLedgerCheck", "WarehouseSelector", "RiskModelInfer", "VaultTokenizer", "LedgerJournal"],
                    ["PostgresPool", "RedisPipeline", "KafkaProducer", "OutboxRelay", "GrpcClientStub", "HttpRetryClient", "CircuitBreaker", "BulkheadIsolator"],
                    ["SocketChannel", "TLSRecordWriter", "ConnectionPooler", "SerializationCodec", "CompressionFilter", "MetricsRecorder", "SpanExporter", "StructuredLogger"],
                    ["KernelEpoll", "NVMeFlush", "ChronosClock", "RingBufferSink", "PrometheusRegistry", "OTelBatchSender"]
                ]
                var rows: [[LayoutNode]] = []
                for (rIdx, rowNames) in stages.enumerated() {
                    var row: [LayoutNode] = []
                    for (cIdx, name) in rowNames.enumerated() {
                        let n = try addLeaf(g, "fn-\(rIdx)-\(cIdx)", name: name, width: 96, height: 30)
                        row.append(n)
                    }
                    rows.append(row)
                }
                for r in 0..<(rows.count - 1) {
                    let cur = rows[r], nxt = rows[r + 1]
                    for (i, s) in cur.enumerated() {
                        link(g, s, nxt[i % nxt.count])
                        link(g, s, nxt[(i + 1) % nxt.count])
                        if i % 2 == 0 { link(g, s, rows[7][6]) } // Hot-spot fan-in to SpanExporter
                    }
                }
                // Retry loops
                link(g, rows[6][5], rows[6][5])
                link(g, rows[6][6], rows[4][6])

                if let ctx = SEBackendContext.active {
                    let builder = LayoutBuilder.create(g)
                        .analyzePageRank(backend: ctx.backend, executor: ctx.executor)
                        .transform { graph in
                            for node in graph.nodes {
                                let pr = node.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0
                                let scale = min(1.85, 1.0 + 3.5 * pr)
                                node.width = (node.width * scale).rounded()
                                node.height = (node.height * scale).rounded()
                            }
                        }
                        .useHierarchical(backend: ctx.backend, executor: ctx.executor) { $0.nodeSeparation = 64; $0.layerSeparation = 115 }
                        .removeOverlaps(backend: ctx.backend, executor: ctx.executor)
                        .routePolyline(backend: ctx.backend, executor: ctx.executor)
                        .separateEdges(backend: ctx.backend, executor: ctx.executor)
                        .routeSelfLoops(backend: ctx.backend, executor: ctx.executor)
                        .clipEdgeEndpoints(backend: ctx.backend, executor: ctx.executor)
                        .distributePorts(backend: ctx.backend, executor: ctx.executor)
                    try await builder.applyAsync()
                    SEBackendContext.recorder?.metrics += builder.lastExecutionMetrics
                } else {
                    try await LayoutBuilder.create(g)
                        .analyzePageRank()
                        .transform { graph in
                            for node in graph.nodes {
                                let pr = node.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0
                                let scale = min(1.85, 1.0 + 3.5 * pr)
                                node.width = (node.width * scale).rounded()
                                node.height = (node.height * scale).rounded()
                            }
                        }
                        .useHierarchical { $0.nodeSeparation = 64; $0.layerSeparation = 115 }
                        .removeOverlaps()
                        .routePolyline()
                        .separateEdges()
                        .routeSelfLoops()
                        .clipEdgeEndpoints()
                        .distributePorts()
                        .applyAsync()
                }
                return VisualDrawing(
                    graph: g,
                    reportedMetrics: ["scaleTier": 2, "stageCount": Double(stages.count), "maxNodeWidth": g.nodes.map(\.width).max() ?? 0],
                    notes: ["52-node distributed trace call graph where node dimensions scale with PageRank centrality (highlighting hot-path dispatchers and telemetry sinks)."]
                )
            },

            VisualCase(
                id: "se-callgraph-profiler-large",
                family: "engineering",
                title: "SE Call Graph · Large clustered subsystem profiler (180 nodes)",
                configuration: ["domain": "callgraph", "scale": "large", "pipeline": "applyClusterBased(Hierarchical) → Separate → Clip → PortDistributor"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true)
            ) {
                let g = LayoutGraph()
                let subsystems = ["RenderEngine", "PhysicsWorld", "AudioMixer", "AssetPipeline", "NetcodeSync"]
                var clusters: [[LayoutNode]] = []
                for sub in subsystems {
                    var group: [LayoutNode] = []
                    for i in 0..<36 {
                        let n = try addLeaf(g, "\(sub)-\(i)", name: "\(sub.prefix(6))::fn\(i)", width: 92 + Double(i % 3) * 10, height: 30)
                        group.append(n)
                        if i > 0 {
                            link(g, group[(i - 1) / 2], n)
                            if i > 3 && i % 3 == 0 { link(g, group[i - 3], n) }
                        }
                        if i == 5 { link(g, n, n) } // Recursive hot-loop per subsystem
                    }
                    clusters.append(group)
                }
                // Cross-subsystem call bridges
                for s in 0..<(clusters.count - 1) {
                    link(g, clusters[s][0], clusters[s + 1][0])
                    link(g, clusters[s][8], clusters[s + 1][2])
                    link(g, clusters[s][15], clusters[s + 1][4])
                }
                if let ctx = SEBackendContext.active {
                    let core = HierarchicalLayoutOperation(backend: ctx.backend, executor: ctx.executor)
                    let builder = LayoutBuilder.create(g)
                        .applyClusterBased(core, backend: ctx.backend, executor: ctx.executor)
                        .separateEdges(backend: ctx.backend, executor: ctx.executor)
                        .clipEdgeEndpoints(backend: ctx.backend, executor: ctx.executor)
                        .distributePorts(backend: ctx.backend, executor: ctx.executor)
                    try await builder.applyAsync()
                    SEBackendContext.recorder?.metrics += builder.lastExecutionMetrics
                } else {
                    try await LayoutBuilder.create(g)
                        .applyClusterBased(HierarchicalLayoutAlgorithm())
                        .separateEdges()
                        .clipEdgeEndpoints()
                        .distributePorts()
                        .applyAsync()
                }
                return VisualDrawing(
                    graph: g,
                    reportedMetrics: ["scaleTier": 3, "subsystemCount": 5, "nodeCount": Double(g.nodes.count)],
                    notes: ["Large 180-node profiler call graph across 5 engine subsystems using label-propagation clustering and obstacle-avoiding inter-cluster routing."]
                )
            }
        ]
    }

    // MARK: - 4. State Machines & Protocol Flows

    private static func stateMachineCases() -> [VisualCase] {
        [
            VisualCase(
                id: "se-state-protocol-small",
                family: "engineering",
                title: "SE State Machine · Small TCP/WebSocket protocol with guard labels",
                configuration: ["domain": "statemachine", "scale": "small", "pipeline": "DirectedLayoutOperation → LabelLayoutAlgorithm"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, orthogonal: true, noLabelOverlaps: true),
                smoke: true
            ) {
                let g = LayoutGraph()
                let states = [
                    "CLOSED", "LISTEN", "SYN_SENT", "SYN_RCVD", "ESTABLISHED",
                    "FIN_WAIT_1", "FIN_WAIT_2", "CLOSE_WAIT", "CLOSING", "LAST_ACK", "TIME_WAIT", "RESET_ERR"
                ]
                for s in states { try addLeaf(g, s, width: 112, height: 38) }
                let byID = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0) })
                let transitions: [(String, String, String?)] = [
                    ("CLOSED", "LISTEN", "passiveOpen"),
                    ("CLOSED", "SYN_SENT", "activeOpen"),
                    ("LISTEN", "SYN_RCVD", "rxSYN"),
                    ("SYN_SENT", "SYN_RCVD", "rxSYN"),
                    ("SYN_RCVD", "SYN_SENT", "retrySYN"),
                    ("SYN_SENT", "ESTABLISHED", "rxSYN+ACK"),
                    ("SYN_RCVD", "ESTABLISHED", "rxACK"),
                    ("ESTABLISHED", "ESTABLISHED", nil), // keepalive loop
                    ("ESTABLISHED", "ESTABLISHED", nil), // data frame loop
                    ("ESTABLISHED", "FIN_WAIT_1", "close()"),
                    ("ESTABLISHED", "CLOSE_WAIT", "rxFIN"),
                    ("FIN_WAIT_1", "FIN_WAIT_2", "rxACK"),
                    ("FIN_WAIT_1", "CLOSING", "rxFIN"),
                    ("FIN_WAIT_2", "TIME_WAIT", "rxFIN"),
                    ("CLOSE_WAIT", "LAST_ACK", "sendFIN"),
                    ("CLOSING", "TIME_WAIT", "rxACK"),
                    ("LAST_ACK", "CLOSED", "rxACK"),
                    ("TIME_WAIT", "CLOSED", "2MSLTimeout"),
                    ("SYN_RCVD", "RESET_ERR", "rxRST"),
                    ("ESTABLISHED", "RESET_ERR", nil),
                    ("RESET_ERR", "CLOSED", nil)
                ]
                for (s, t, lbl) in transitions {
                    link(g, byID[s]!, byID[t]!, label: lbl, labelSize: Size(width: 74, height: 18))
                }
                var config = DirectedLayoutConfiguration()
                config.nodeSpacing = 68; config.layerSpacing = 140
                let diag: DirectedLayoutDiagnostics
                if let ctx = SEBackendContext.active {
                    let op = DirectedLayoutAsyncOperation(backend: ctx.backend, executor: ctx.executor, configuration: config)
                    try await op.applyLayoutAsync(g)
                    let lbl = RoutingLayoutOperation(.labelLayout, backend: ctx.backend, executor: ctx.executor)
                    try await lbl.applyLayoutAsync(g)
                    SEBackendContext.recorder?.metrics += op.lastExecutionMetrics + lbl.lastExecutionMetrics
                    diag = op.lastDiagnostics!
                } else {
                    diag = try DirectedLayoutOperation(configuration: config).apply(g)
                    LabelLayoutAlgorithm().applyLabelLayout(g)
                }
                return VisualDrawing(
                    graph: g,
                    reportedMetrics: ["scaleTier": 1, "crossings": Double(diag.crossings), "bends": Double(diag.bends)],
                    notes: ["12-state TCP protocol machine with reciprocal SYN_SENT<->SYN_RCVD transitions, dual self-loops on ESTABLISHED, and collision-free transition guard labels."]
                )
            },

            VisualCase(
                id: "se-state-workflow-medium",
                family: "engineering",
                title: "SE State Machine · Medium order saga & compensation statechart",
                configuration: ["domain": "statemachine", "scale": "medium", "pipeline": "Hierarchical → Polyline → Separate → SelfLoop → Clip → LabelLayout"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, noLabelOverlaps: true)
            ) {
                let g = LayoutGraph()
                let phases = ["Draft", "Validated", "Reserved", "Charged", "Picked", "Packed", "Shipped", "Delivered"]
                var happy: [LayoutNode] = [], audit: [LayoutNode] = [], retry: [LayoutNode] = [], comp: [LayoutNode] = [], terminal: [LayoutNode] = []
                for (i, p) in phases.enumerated() {
                    happy.append(try addLeaf(g, "st-\(p.lowercased())", name: "\(p)State", width: 112, height: 36))
                    audit.append(try addLeaf(g, "ev-\(p.lowercased())", name: "\(p)EventOutbox", width: 120, height: 34))
                    retry.append(try addLeaf(g, "rt-\(p.lowercased())", name: "\(p)RetryWait", width: 114, height: 34))
                    comp.append(try addLeaf(g, "cp-\(p.lowercased())", name: "Undo\(p)", width: 108, height: 34))
                    if i < 6 {
                        terminal.append(try addLeaf(g, "dlq-\(i)", name: "DLQStage\(i)", width: 102, height: 32))
                    }
                }
                let refunded = try addLeaf(g, "st-refunded", name: "RefundedFinal", width: 118, height: 38)
                let archived = try addLeaf(g, "st-archived", name: "ArchivedFinal", width: 118, height: 38)

                for i in phases.indices {
                    link(g, happy[i], audit[i], label: i % 2 == 0 ? "emitEvt" : nil, labelSize: Size(width: 58, height: 16))
                    link(g, happy[i], retry[i])
                    link(g, retry[i], retry[i]) // backoff self-loop
                    link(g, retry[i], comp[i], label: i % 3 == 0 ? "maxRetry" : nil, labelSize: Size(width: 64, height: 16))
                    if i < 6 { link(g, retry[i], terminal[i]) }
                    if i + 1 < phases.count {
                        link(g, happy[i], happy[i + 1], label: i % 2 == 1 ? "onSuccess" : nil, labelSize: Size(width: 68, height: 16))
                        link(g, comp[i + 1], comp[i]) // reverse compensation chain
                    }
                }
                link(g, comp[0], refunded, label: "settled", labelSize: Size(width: 58, height: 16))
                link(g, happy.last!, archived, label: "complete", labelSize: Size(width: 64, height: 16))

                if let ctx = SEBackendContext.active {
                    let builder = LayoutBuilder.create(g)
                        .useHierarchical(backend: ctx.backend, executor: ctx.executor) { $0.nodeSeparation = 58; $0.layerSeparation = 92 }
                        .routePolyline(backend: ctx.backend, executor: ctx.executor)
                        .separateEdges(backend: ctx.backend, executor: ctx.executor)
                        .routeSelfLoops(backend: ctx.backend, executor: ctx.executor)
                        .clipEdgeEndpoints(backend: ctx.backend, executor: ctx.executor)
                        .distributePorts(backend: ctx.backend, executor: ctx.executor)
                        .layoutLabels(backend: ctx.backend, executor: ctx.executor)
                    try await builder.applyAsync()
                    SEBackendContext.recorder?.metrics += builder.lastExecutionMetrics
                } else {
                    let h = HierarchicalLayoutAlgorithm(); h.nodeSeparation = 58; h.layerSeparation = 92
                    try h.applyLayout(g)
                    PolylineEdgeRouter().routeEdges(g)
                    EdgeSeparator().routeEdges(g)
                    SelfLoopRouter().routeEdges(g)
                    EdgeEndpointClipper.clipToNodeBounds(g)
                    PortDistributor().routeEdges(g)
                    LabelLayoutAlgorithm().applyLabelLayout(g)
                }
                return VisualDrawing(
                    graph: g,
                    reportedMetrics: ["scaleTier": 2, "stateCount": Double(g.nodes.count), "labeledEdges": Double(g.edges.filter { $0.data != nil }.count)],
                    notes: ["40-node distributed saga statechart with forward happy path, retry self-loops, reverse compensation chain, and non-overlapping guard labels."]
                )
            },

            VisualCase(
                id: "se-state-automaton-large",
                family: "engineering",
                title: "SE State Machine · Large hierarchical UI/engine statechart (162 nodes)",
                configuration: ["domain": "statemachine", "scale": "large", "pipeline": "RecursiveGroupLayout (6 composite super-states) → clip"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, framedGroups: true)
            ) {
                let g = LayoutGraph()
                let superStates = ["BootSequence", "Authentication", "MainLobby", "Matchmaking", "ActiveGameplay", "PostMatchSummary"]
                var superFrames: [LayoutNode] = []
                var entryStates: [LayoutNode] = [], exitStates: [LayoutNode] = []
                let crashHandler = try addLeaf(g, "global-crash", name: "GlobalCrashRecovery", width: 146, height: 40)
                let netReconnect = try addLeaf(g, "global-reconnect", name: "NetworkReconnectOverlay", width: 156, height: 40)
                link(g, netReconnect, crashHandler)

                for (sIdx, sName) in superStates.enumerated() {
                    let frame = try addFrame(g, "super-\(sIdx)", title: "SuperState · \(sName)", headerWidth: 230)
                    superFrames.append(frame)
                    var sub: [LayoutNode] = []
                    for i in 0..<25 {
                        let st = try addLeaf(g, "st-\(sIdx)-\(i)", name: "\(sName.prefix(5))_S\(i)", width: 94 + Double(i % 3) * 10, height: 32, parent: frame)
                        sub.append(st)
                        if i > 0 {
                            link(g, sub[(i - 1) / 3], st)
                            if i > 4 && i % 5 == 0 { link(g, st, sub[(i - 2) / 3]) } // local state cycle
                        }
                        if i == 3 { link(g, st, st) } // internal self-transition
                    }
                    entryStates.append(sub[0])
                    exitStates.append(sub[sub.count - 1])
                }
                // Branching super-state progression across 3 tiers
                link(g, exitStates[0], entryStates[1])
                link(g, exitStates[0], entryStates[2])
                link(g, exitStates[1], entryStates[2])
                link(g, exitStates[1], entryStates[3])
                link(g, exitStates[2], entryStates[3])
                link(g, exitStates[2], entryStates[4])
                link(g, exitStates[3], entryStates[4])
                link(g, exitStates[4], entryStates[5])
                link(g, exitStates[5], entryStates[2]) // PostMatch -> MainLobby loop
                for i in [1, 3, 4] {
                    link(g, exitStates[i], netReconnect)
                    link(g, exitStates[i], crashHandler)
                }

                let fallbacks: [Int]
                if let ctx = SEBackendContext.active {
                    let core = LoopAwareAsyncLayout(HierarchicalLayoutOperation(backend: ctx.backend, executor: ctx.executor), backend: ctx.backend, executor: ctx.executor)
                    let layout = RecursiveGroupLayoutOperation(core, backend: ctx.backend, executor: ctx.executor)
                    try await layout.applyLayoutAsync(g)
                    let clip = RoutingLayoutOperation(.endpointClipping, backend: ctx.backend, executor: ctx.executor)
                    try await clip.applyLayoutAsync(g)
                    PortDistributor().routeEdges(g)
                    SEBackendContext.recorder?.metrics += layout.lastExecutionMetrics + clip.lastExecutionMetrics
                    fallbacks = layout.unroutableEdges.compactMap { g.edges.firstIndex(of: $0) }
                } else {
                    let layout = RecursiveGroupLayout(LoopAwareLayout(HierarchicalLayoutAlgorithm()))
                    try layout.applyLayout(g)
                    EdgeEndpointClipper.clipToNodeBounds(g)
                    PortDistributor().routeEdges(g)
                    fallbacks = layout.unroutableEdges.compactMap { g.edges.firstIndex(of: $0) }
                }
                return VisualDrawing(
                    graph: g,
                    fallbackEdges: fallbacks,
                    reportedMetrics: ["scaleTier": 3, "superStateCount": 6, "leafStateCount": Double(g.nodes.filter { !$0.isGroup }.count)],
                    notes: ["Large 162-node hierarchical statechart with 6 composite super-state frames, local cyclic transitions, internal self-loops, and global interrupt recovery."]
                )
            }
        ]
    }

    // MARK: - 5. CI/CD Pipelines, Swimlanes & Data Flow

    private static func pipelineAndDataFlowCases() -> [VisualCase] {
        [
            VisualCase(
                id: "se-swimlane-cicd-small",
                family: "engineering",
                title: "SE Swimlane · Small 4-lane CI/CD deployment pipeline",
                configuration: ["domain": "pipeline", "scale": "small", "pipeline": "Swimlane → Channel → EdgeSeparator → SelfLoop → Clip"],
                contracts: VisualContracts(noNodeOverlaps: true)
            ) {
                let g = LayoutGraph()
                let steps: [(String, String, Int)] = [
                    ("git-push", "Git Push PR", 0), ("pre-commit", "Pre-Commit Hooks", 0), ("dev-fix", "Developer Hotfix", 0),
                    ("lint-check", "SwiftFormat & Lint", 1), ("unit-tests", "Unit Test Matrix", 1), ("asan-build", "ASan Memory Audit", 1),
                    ("docker-pkg", "Build OCI Image", 1), ("sbom-sign", "Cosign & SBOM", 1),
                    ("deploy-stg", "Deploy Staging", 2), ("e2e-suite", "Playwright E2E", 2), ("perf-gate", "Latency Gate", 2), ("stg-rollback", "Rollback Staging", 2),
                    ("canary-10", "Canary 10% Traffic", 3), ("slo-monitor", "SLO Burn Check", 3), ("prod-100", "Promote 100% Prod", 3), ("prod-alert", "Auto-Rollback Prod", 3)
                ]
                var lanes: [String: Int] = [:]
                for (id, title, lane) in steps {
                    try addLeaf(g, id, name: title, width: 124, height: 36)
                    lanes[id] = lane
                }
                let byID = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0) })
                let flow: [(String, String)] = [
                    ("git-push", "pre-commit"), ("pre-commit", "lint-check"), ("pre-commit", "unit-tests"), ("pre-commit", "asan-build"),
                    ("lint-check", "docker-pkg"), ("unit-tests", "docker-pkg"), ("asan-build", "docker-pkg"),
                    ("docker-pkg", "sbom-sign"), ("sbom-sign", "deploy-stg"),
                    ("deploy-stg", "e2e-suite"), ("deploy-stg", "perf-gate"),
                    ("e2e-suite", "canary-10"), ("perf-gate", "canary-10"),
                    ("perf-gate", "stg-rollback"), ("stg-rollback", "dev-fix"), ("dev-fix", "git-push"),
                    ("canary-10", "slo-monitor"), ("slo-monitor", "prod-100"),
                    ("slo-monitor", "prod-alert"), ("prod-alert", "stg-rollback"),
                    ("unit-tests", "unit-tests") // flaky retry self-loop
                ]
                for (s, t) in flow { link(g, byID[s]!, byID[t]!) }
                let fallbacks: [Int]
                let laneCount: Int
                if let ctx = SEBackendContext.active {
                    let swim = SwimlaneLayoutOperation(backend: ctx.backend, executor: ctx.executor)
                    swim.laneAssignment = lanes; swim.laneWidth = 220; swim.laneSpacing = 36; swim.nodeVerticalSpacing = 36
                    try await swim.applyLayoutAsync(g)
                    let router = RoutingLayoutOperation(.channel, backend: ctx.backend, executor: ctx.executor)
                    try await router.applyLayoutAsync(g)
                    let sep = RoutingLayoutOperation(.edgeSeparation, backend: ctx.backend, executor: ctx.executor)
                    try await sep.applyLayoutAsync(g)
                    let loops = RoutingLayoutOperation(.selfLoops, backend: ctx.backend, executor: ctx.executor)
                    try await loops.applyLayoutAsync(g)
                    let clip = RoutingLayoutOperation(.endpointClipping, backend: ctx.backend, executor: ctx.executor)
                    try await clip.applyLayoutAsync(g)
                    PortDistributor().routeEdges(g)
                    SEBackendContext.recorder?.metrics += swim.lastExecutionMetrics + router.lastExecutionMetrics + sep.lastExecutionMetrics + loops.lastExecutionMetrics + clip.lastExecutionMetrics
                    fallbacks = router.unroutableEdgeIndices
                    laneCount = swim.computedLanes.count
                } else {
                    let swim = SwimlaneLayoutAlgorithm()
                    swim.laneAssignment = lanes; swim.laneWidth = 220; swim.laneSpacing = 36; swim.nodeVerticalSpacing = 36
                    try swim.applyLayout(g)
                    let router = ChannelEdgeRouter(); router.routeEdges(g)
                    EdgeSeparator().routeEdges(g)
                    SelfLoopRouter().routeEdges(g)
                    EdgeEndpointClipper.clipToNodeBounds(g)
                    PortDistributor().routeEdges(g)
                    fallbacks = VisualCatalogue.fallbacks(router, g)
                    laneCount = swim.computedLanes.count
                }
                return VisualDrawing(
                    graph: g,
                    fallbackEdges: fallbacks,
                    reportedMetrics: ["scaleTier": 1, "laneCount": Double(laneCount), "nodeCount": Double(g.nodes.count)],
                    notes: ["4-lane CI/CD swimlane workflow (Dev, CI Runner, Staging, Production) with parallel test gates and rollback loops."]
                )
            },

            VisualCase(
                id: "se-swimlane-saga-medium",
                family: "engineering",
                title: "SE Swimlane · Medium 6-lane cross-service choreography (54 nodes)",
                configuration: ["domain": "pipeline", "scale": "medium", "pipeline": "Swimlane → Polyline → EdgeSeparator → SelfLoop → Clip → PortDistributor"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true)
            ) {
                let g = LayoutGraph()
                let laneTitles = ["MobileClient", "APIGateway", "IdentitySvc", "BillingSvc", "FulfillmentSvc", "NotifySvc"]
                var lanes: [String: Int] = [:]
                var matrix: [[LayoutNode]] = []
                for rank in 0..<9 {
                    var row: [LayoutNode] = []
                    for (laneIdx, lName) in laneTitles.enumerated() {
                        let id = "lane\(laneIdx)-step\(rank)"
                        let n = try addLeaf(g, id, name: "\(lName.prefix(7))·S\(rank)", width: 108, height: 34)
                        lanes[id] = laneIdx
                        row.append(n)
                    }
                    matrix.append(row)
                }
                for r in 0..<8 {
                    for l in 0..<6 {
                        link(g, matrix[r][l], matrix[r + 1][l]) // intra-lane progression
                        if (r + l) % 2 == 0 && l + 1 < 6 {
                            link(g, matrix[r][l], matrix[r + 1][l + 1]) // cross-lane handoff right
                        }
                        if (r + l) % 3 == 0 && l > 0 {
                            link(g, matrix[r][l], matrix[r + 1][l - 1]) // cross-lane callback left
                        }
                    }
                    // Skip-lane async event notifications to NotifySvc (lane 5)
                    if r % 2 == 0 { link(g, matrix[r][1], matrix[r + 1][5]) }
                }
                link(g, matrix[3][3], matrix[3][3]) // payment poll self-loop

                let laneCount: Int
                if let ctx = SEBackendContext.active {
                    let swim = SwimlaneLayoutOperation(backend: ctx.backend, executor: ctx.executor)
                    swim.laneAssignment = lanes; swim.laneWidth = 210; swim.laneSpacing = 44; swim.nodeVerticalSpacing = 42
                    try await swim.applyLayoutAsync(g)
                    for e in g.edges { e.sourcePort = .none; e.targetPort = .none }
                    let builder = LayoutBuilder.create(g)
                        .routePolyline(backend: ctx.backend, executor: ctx.executor)
                        .separateEdges(backend: ctx.backend, executor: ctx.executor)
                        .routeSelfLoops(backend: ctx.backend, executor: ctx.executor)
                        .clipEdgeEndpoints(backend: ctx.backend, executor: ctx.executor)
                        .distributePorts(backend: ctx.backend, executor: ctx.executor)
                    try await builder.applyAsync()
                    SEBackendContext.recorder?.metrics += swim.lastExecutionMetrics + builder.lastExecutionMetrics
                    laneCount = swim.computedLanes.count
                } else {
                    let swim = SwimlaneLayoutAlgorithm()
                    swim.laneAssignment = lanes; swim.laneWidth = 210; swim.laneSpacing = 44; swim.nodeVerticalSpacing = 42
                    try swim.applyLayout(g)
                    for e in g.edges { e.sourcePort = .none; e.targetPort = .none }
                    PolylineEdgeRouter().routeEdges(g)
                    EdgeSeparator().routeEdges(g)
                    SelfLoopRouter().routeEdges(g)
                    EdgeEndpointClipper.clipToNodeBounds(g)
                    PortDistributor().routeEdges(g)
                    laneCount = swim.computedLanes.count
                }
                return VisualDrawing(
                    graph: g,
                    reportedMetrics: ["scaleTier": 2, "laneCount": Double(laneCount), "nodeCount": Double(g.nodes.count)],
                    notes: ["Medium 54-node, 6-lane distributed service choreography with cross-lane handoffs, skip-lane notifications, and obstacle-avoiding polyline lanes."]
                )
            },

            VisualCase(
                id: "se-dataflow-lineage-large",
                family: "engineering",
                title: "SE Data Flow · Large 10-stage streaming & ETL data lineage (160 nodes)",
                configuration: ["domain": "pipeline", "scale": "large", "pipeline": "DirectedLayoutOperation (.fresh, 4 parallel 10-stage pipelines)"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, orthogonal: true)
            ) {
                let g = LayoutGraph()
                let stagePrefixes = ["Src", "Ingest", "RawLake", "Cleanse", "Enrich", "Join", "Feature", "Model", "Mart", "BI"]
                for stream in 0..<4 {
                    var stages: [[LayoutNode]] = []
                    for (sIdx, prefix) in stagePrefixes.enumerated() {
                        var col: [LayoutNode] = []
                        for i in 0..<4 {
                            let isTable = sIdx % 2 == 0
                            let n = try addLeaf(g, "S\(stream)-\(prefix)-\(i)", name: "S\(stream)·\(prefix)\(i)", width: isTable ? 116 : 94, height: isTable ? 40 : 30)
                            col.append(n)
                        }
                        stages.append(col)
                    }
                    for s in 0..<(stages.count - 1) {
                        for i in 0..<4 {
                            link(g, stages[s][i], stages[s + 1][i])
                            if i % 2 == 0 { link(g, stages[s][i], stages[s + 1][(i + 1) % 4]) }
                            if i == 0 && s + 2 < stages.count { link(g, stages[s][i], stages[s + 2][(i + 1) % 4]) }
                        }
                    }
                    // Lineage quality feedback loop per stream
                    link(g, stages[5][0], stages[3][0])
                }

                var config = DirectedLayoutConfiguration()
                config.candidateCount = 1; config.nodeSpacing = 28; config.layerSpacing = 96
                let diag: DirectedLayoutDiagnostics
                if let ctx = SEBackendContext.active {
                    let op = DirectedLayoutAsyncOperation(backend: ctx.backend, executor: ctx.executor, configuration: config)
                    try await op.applyLayoutAsync(g)
                    SEBackendContext.recorder?.metrics += op.lastExecutionMetrics
                    diag = op.lastDiagnostics!
                } else {
                    diag = try DirectedLayoutOperation(configuration: config).apply(g)
                }
                return VisualDrawing(
                    graph: g,
                    reportedMetrics: ["scaleTier": 3, "stageCount": 10, "streamCount": 4, "crossings": Double(diag.crossings), "bends": Double(diag.bends)],
                    notes: ["Large 160-node, 10-stage enterprise data lineage DAG across 4 streaming pipelines mixing wide table nodes and compact stream operators."]
                )
            }
        ]
    }

    // MARK: - 6. ER Schemas, Incremental Expansion & Constrained Corridors

    private static func schemaAndConstrainedCases() -> [VisualCase] {
        [
            VisualCase(
                id: "se-schema-er-small",
                family: "engineering",
                title: "SE Schema · Small e-commerce entity-relationship diagram",
                configuration: ["domain": "schema", "scale": "small", "pipeline": "DirectedLayoutOperation → LabelLayoutAlgorithm"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, orthogonal: true, noLabelOverlaps: true)
            ) {
                let g = LayoutGraph()
                // Tall boxes simulate database tables with varying numbers of columns
                let tables: [(String, Double, Double)] = [
                    ("users", 128, 72), ("roles", 112, 48), ("user_roles", 118, 44),
                    ("addresses", 128, 68), ("categories", 124, 56), ("products", 132, 78),
                    ("inventory_lots", 130, 58), ("carts", 116, 52), ("cart_items", 122, 54),
                    ("orders", 134, 84), ("order_items", 128, 62), ("payments", 126, 68),
                    ("shipments", 126, 64), ("reviews", 118, 56), ("audit_logs", 128, 60)
                ]
                for (name, w, h) in tables { try addLeaf(g, name, name: "tbl: \(name)", width: w, height: h) }
                let byID = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0) })
                let fks: [(String, String, String?)] = [
                    ("user_roles", "users", "N:1"), ("user_roles", "roles", "N:1"),
                    ("addresses", "users", "N:1"),
                    ("categories", "categories", nil), // self-referential parent_category_id
                    ("products", "categories", "N:1"), ("inventory_lots", "products", "N:1"),
                    ("carts", "users", "1:1"), ("cart_items", "carts", "N:1"), ("cart_items", "products", "N:1"),
                    ("orders", "users", "N:1"),
                    ("orders", "addresses", "billing"), ("orders", "addresses", "shipping"), // dual FK between same pair
                    ("order_items", "orders", "N:1"), ("order_items", "products", "N:1"),
                    ("payments", "orders", "N:1"), ("shipments", "orders", "N:1"), ("shipments", "addresses", nil),
                    ("reviews", "users", nil), ("reviews", "products", "N:1"),
                    ("audit_logs", "users", nil), ("audit_logs", "orders", nil), ("audit_logs", "payments", nil)
                ]
                for (s, t, card) in fks {
                    link(g, byID[s]!, byID[t]!, label: card, labelSize: Size(width: 56, height: 18))
                }
                var config = DirectedLayoutConfiguration()
                config.nodeSpacing = 56; config.layerSpacing = 130
                let diag: DirectedLayoutDiagnostics
                if let ctx = SEBackendContext.active {
                    let op = DirectedLayoutAsyncOperation(backend: ctx.backend, executor: ctx.executor, configuration: config)
                    try await op.applyLayoutAsync(g)
                    let lbl = RoutingLayoutOperation(.labelLayout, backend: ctx.backend, executor: ctx.executor)
                    try await lbl.applyLayoutAsync(g)
                    SEBackendContext.recorder?.metrics += op.lastExecutionMetrics + lbl.lastExecutionMetrics
                    diag = op.lastDiagnostics!
                } else {
                    diag = try DirectedLayoutOperation(configuration: config).apply(g)
                    LabelLayoutAlgorithm().applyLabelLayout(g)
                }
                return VisualDrawing(
                    graph: g,
                    reportedMetrics: ["scaleTier": 1, "tableCount": Double(g.nodes.count), "crossings": Double(diag.crossings)],
                    notes: ["15-table relational ER schema with tall multi-column table boxes, self-referential categories.parent_id, dual orders->addresses FKs, and cardinality labels."]
                )
            },

            VisualCase(
                id: "se-schema-saas-medium",
                family: "engineering",
                title: "SE Schema · Medium multi-tenant SaaS schema with BSP routing",
                configuration: ["domain": "schema", "scale": "medium", "pipeline": "ComponentLayout(Hierarchical) → BspEdgeRouter → SelfLoop → Clip → PortDistributor"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, orthogonal: true)
            ) {
                let g = LayoutGraph()
                let modules = ["IAM", "Billing", "Workspace", "Projects", "Workflows", "Webhooks", "Audit"]
                var modNodes: [[LayoutNode]] = []
                for (mIdx, mod) in modules.enumerated() {
                    var tables: [LayoutNode] = []
                    for i in 0..<8 {
                        let h = 42.0 + Double((mIdx + i) % 4) * 14.0
                        let n = try addLeaf(g, "\(mod.lowercased())_tbl_\(i)", name: "\(mod)_T\(i)", width: 118, height: h)
                        tables.append(n)
                        if i > 0 { link(g, tables[i], tables[(i - 1) / 2]) }
                    }
                    modNodes.append(tables)
                }
                // Cross-module foreign keys into IAM tenant/user roots, leaving Audit (last module) as a separate component
                for m in 1..<5 {
                    link(g, modNodes[m][0], modNodes[0][0])
                    link(g, modNodes[m][1], modNodes[0][1])
                }
                link(g, modNodes[0][2], modNodes[0][2]) // org hierarchy self-reference

                let fallbacks: [Int]
                if let ctx = SEBackendContext.active {
                    var hc = HierarchicalLayoutConfiguration(); hc.nodeSeparation = 72; hc.layerSeparation = 128
                    let core = HierarchicalLayoutOperation(backend: ctx.backend, executor: ctx.executor, configuration: hc)
                    let comp = ComponentLayoutOperation(core, backend: ctx.backend, executor: ctx.executor)
                    comp.componentSpacing = 70; comp.preferredAspectRatio = 1.35
                    try await comp.applyLayoutAsync(g)
                    let bsp = RoutingLayoutOperation(.bsp, backend: ctx.backend, executor: ctx.executor)
                    try await bsp.applyLayoutAsync(g)
                    let loops = RoutingLayoutOperation(.selfLoops, backend: ctx.backend, executor: ctx.executor)
                    try await loops.applyLayoutAsync(g)
                    let clip = RoutingLayoutOperation(.endpointClipping, backend: ctx.backend, executor: ctx.executor)
                    try await clip.applyLayoutAsync(g)
                    PortDistributor().routeEdges(g)
                    SEBackendContext.recorder?.metrics += comp.lastExecutionMetrics + bsp.lastExecutionMetrics + loops.lastExecutionMetrics + clip.lastExecutionMetrics
                    fallbacks = bsp.unroutableEdgeIndices
                } else {
                    let core = HierarchicalLayoutAlgorithm(); core.nodeSeparation = 72; core.layerSeparation = 128
                    let comp = ComponentLayout(core); comp.componentSpacing = 70; comp.preferredAspectRatio = 1.35
                    try comp.applyLayout(g)
                    let bsp = BspEdgeRouter(); bsp.routeEdges(g)
                    SelfLoopRouter().routeEdges(g)
                    EdgeEndpointClipper.clipToNodeBounds(g)
                    PortDistributor().routeEdges(g)
                    fallbacks = VisualCatalogue.fallbacks(bsp, g)
                }
                return VisualDrawing(
                    graph: g,
                    fallbackEdges: fallbacks,
                    reportedMetrics: ["scaleTier": 2, "tableCount": Double(g.nodes.count), "unroutable": Double(fallbacks.count)],
                    notes: ["56-table multi-tenant SaaS schema routed with orthogonal BspEdgeRouter around tall varying-height table boxes."]
                )
            },

            VisualCase(
                id: "se-schema-knowledge-large",
                family: "engineering",
                title: "SE Schema · Large ontology & knowledge graph (160 nodes)",
                configuration: ["domain": "schema", "scale": "large", "pipeline": "PageRank hub ring + Organic subset (60 iter) → Polyline → SelfLoop → Clip → PortDistributor"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true)
            ) {
                let g = LayoutGraph()
                let hubNames = ["EntityRoot", "ServiceAsset", "TeamOwner", "SLOContract", "SecurityZone"]
                var hubs: [LayoutNode] = []
                for (i, hName) in hubNames.enumerated() {
                    let h = try addLeaf(g, "hub-\(i)", name: hName, width: 132, height: 42)
                    let angle = 2.0 * Double.pi * Double(i) / Double(hubNames.count)
                    h.center = Point(x: 420 * cos(angle), y: 420 * sin(angle))
                    h.metadata[GraphMetadataKeys.fixed] = true
                    hubs.append(h)
                }
                for i in hubs.indices { link(g, hubs[i], hubs[(i + 1) % hubs.count]) }

                var satellites: [LayoutNode] = []
                for i in 0..<155 {
                    let hubIdx = i % hubs.count
                    let sat = try addLeaf(g, "ont-\(i)", name: "Concept_\(i)", width: 88 + Double(i % 3) * 10, height: 30)
                    let baseAngle = 2.0 * Double.pi * Double(hubIdx) / Double(hubNames.count) + Double(i / 5) * 0.18
                    let radius = 180.0 + Double(i % 7) * 65.0
                    sat.center = Point(x: radius * cos(baseAngle), y: radius * sin(baseAngle))
                    sat.metadata[GraphMetadataKeys.layoutSubset] = true
                    satellites.append(sat)
                    if i < 30 {
                        link(g, sat, hubs[hubIdx])
                    } else {
                        link(g, sat, satellites[i - 25])
                        if i % 9 == 0 { link(g, sat, satellites[i - 10]) }
                    }
                }
                var drawing = VisualDrawing(graph: g)
                for h in hubs { drawing.fixedCenters[h.id] = h.center }

                if let ctx = SEBackendContext.active {
                    var oc = OrganicLayoutConfiguration()
                    oc.scope = .subset; oc.iterations = 60; oc.initialization = .current
                    let organic = OrganicLayoutOperation(backend: ctx.backend, executor: ctx.executor, configuration: oc)
                    try await organic.applyLayoutAsync(g)
                    let builder = LayoutBuilder.create(g)
                        .routePolyline(backend: ctx.backend, executor: ctx.executor)
                        .routeSelfLoops(backend: ctx.backend, executor: ctx.executor)
                        .clipEdgeEndpoints(backend: ctx.backend, executor: ctx.executor)
                        .distributePorts(backend: ctx.backend, executor: ctx.executor)
                    try await builder.applyAsync()
                    SEBackendContext.recorder?.metrics += organic.lastExecutionMetrics + builder.lastExecutionMetrics
                } else {
                    let organic = OrganicLayoutAlgorithm()
                    organic.scope = .subset; organic.iterations = 60; organic.initialization = .current
                    try organic.applyLayout(g)
                    PolylineEdgeRouter().routeEdges(g)
                    SelfLoopRouter().routeEdges(g)
                    EdgeEndpointClipper.clipToNodeBounds(g)
                    PortDistributor().routeEdges(g)
                }
                drawing.reportedMetrics = ["scaleTier": 3, "pinnedHubs": 5, "totalNodes": Double(g.nodes.count)]
                drawing.notes = ["Large 160-node enterprise ontology knowledge graph with 5 pinned core hubs and 155 organic-subset concept nodes."]
                return drawing
            },

            VisualCase(
                id: "se-incremental-expand-medium",
                family: "engineering",
                title: "SE Incremental · Medium interactive subsystem expansion (32 fixed + 13 inserted)",
                configuration: ["domain": "incremental", "scale": "medium", "pipeline": "DirectedLayoutOperation (.fresh → .incremental expansion)"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, orthogonal: true)
            ) {
                let g = LayoutGraph()
                for i in 0..<32 {
                    try addLeaf(g, "base-svc-\(i)", name: "CoreSvc-\(i)", width: 102 + Double(i % 3) * 12, height: 34)
                }
                for i in 1..<32 {
                    link(g, g.nodes[(i - 1) / 2], g.nodes[i])
                    if i > 4 && i % 3 == 0 { link(g, g.nodes[i - 4], g.nodes[i]) }
                }
                try DirectedLayoutOperation().apply(g)
                let priorBounds = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.bounds) })
                let priorPaths = Dictionary(uniqueKeysWithValues: g.edges.enumerated().map { ($0.offset, $0.element.path) })

                // Expand CoreSvc-5 and CoreSvc-10 by inserting 13 new sub-components around them
                var config = DirectedLayoutConfiguration()
                config.mode = .incremental
                config.previousBounds = priorBounds
                config.previousPaths = priorPaths
                config.fixedNodeIDs = Set(priorBounds.keys)

                let anchors = [g.nodes[5], g.nodes[10], g.nodes[14]]
                var inserted: [LayoutNode] = []
                for i in 0..<13 {
                    let anchor = anchors[i % anchors.count]
                    let n = try addLeaf(g, "expanded-pod-\(i)", name: "ExpandedPod-\(i)", width: 112, height: 34)
                    config.insertionOrigins[n.id] = anchor.center
                    inserted.append(n)
                    link(g, anchor, n)
                    if i > 0 && i % 3 == 0 { link(g, inserted[i - 1], n) }
                }
                let diag: DirectedLayoutDiagnostics
                if let ctx = SEBackendContext.active {
                    let op = DirectedLayoutAsyncOperation(backend: ctx.backend, executor: ctx.executor, configuration: config)
                    try await op.applyLayoutAsync(g)
                    SEBackendContext.recorder?.metrics += op.lastExecutionMetrics
                    diag = op.lastDiagnostics!
                } else {
                    diag = try DirectedLayoutOperation(configuration: config).apply(g)
                }
                return VisualDrawing(
                    graph: g,
                    previousBounds: priorBounds,
                    fixedCenters: priorBounds.mapValues(\.center),
                    reportedMetrics: ["scaleTier": 2, "fixedNodes": 32, "insertedNodes": 13, "displacement": diag.displacement, "crossings": Double(diag.crossings)],
                    notes: ["Interactive architecture expansion: 32 baseline nodes remain strictly pinned at their prior coordinates while 13 expanded pods slot into free corridors."]
                )
            },

            VisualCase(
                id: "se-constrained-corridor-medium",
                family: "engineering",
                title: "SE Constrained · Medium pinned infrastructure corridor maze (42 nodes)",
                configuration: ["domain": "constrained", "scale": "medium", "pipeline": "GivenCoordinates → Polyline → EdgeSeparator → SelfLoop → Clip → PortDistributor"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true)
            ) {
                let g = LayoutGraph()
                var fixedCenters: [String: Point] = [:]
                // 6x5 grid of pinned rack/subnet blocks forming narrow vertical and horizontal routing corridors
                var grid: [[LayoutNode]] = []
                for row in 0..<5 {
                    var rNodes: [LayoutNode] = []
                    for col in 0..<6 {
                        let n = try addLeaf(g, "rack-r\(row)-c\(col)", name: "Rack[\(row),\(col)]", width: 110, height: 42)
                        n.center = Point(x: Double(col) * 210, y: Double(row) * 130)
                        fixedCenters[n.id] = n.center
                        rNodes.append(n)
                    }
                    grid.append(rNodes)
                }
                // 6 Left ingress gateways and 6 Right egress sinks
                var leftGateways: [LayoutNode] = [], rightSinks: [LayoutNode] = []
                for i in 0..<6 {
                    let lg = try addLeaf(g, "ingress-\(i)", name: "IngressGW-\(i)", width: 116, height: 36)
                    lg.center = Point(x: -240, y: Double(i) * 104 - 20)
                    fixedCenters[lg.id] = lg.center
                    leftGateways.append(lg)

                    let rs = try addLeaf(g, "egress-\(i)", name: "EgressSink-\(i)", width: 116, height: 36)
                    rs.center = Point(x: 6.0 * 210 + 30, y: Double(i) * 104 - 20)
                    fixedCenters[rs.id] = rs.center
                    rightSinks.append(rs)
                }
                // Cross-corridor traffic, duplicate pairs, reciprocals, and self-loops
                for i in 0..<6 {
                    link(g, leftGateways[i], rightSinks[5 - i])
                    link(g, leftGateways[i], grid[i % 5][2])
                    link(g, grid[i % 5][3], rightSinks[i])
                }
                for r in 0..<5 {
                    for c in 0..<5 {
                        link(g, grid[r][c], grid[r][c + 1])
                        if (r + c) % 4 == 0 {
                            link(g, grid[r][c], grid[r][c + 1]) // parallel duplicate lane
                            link(g, grid[r][c + 1], grid[r][c]) // reciprocal lane
                        }
                    }
                    link(g, grid[r][0], grid[(r + 2) % 5][5]) // long diagonal obstacle-avoiding route across the grid
                }
                link(g, leftGateways[0], leftGateways[0])
                link(g, rightSinks[5], rightSinks[5])

                let fallbacks: [Int]
                if let ctx = SEBackendContext.active {
                    let given = RoutingLayoutOperation(.givenCoordinates, backend: ctx.backend, executor: ctx.executor)
                    try await given.applyLayoutAsync(g)
                    let sep = RoutingLayoutOperation(.edgeSeparation, backend: ctx.backend, executor: ctx.executor)
                    try await sep.applyLayoutAsync(g)
                    let loops = RoutingLayoutOperation(.selfLoops, backend: ctx.backend, executor: ctx.executor)
                    try await loops.applyLayoutAsync(g)
                    let clip = RoutingLayoutOperation(.endpointClipping, backend: ctx.backend, executor: ctx.executor)
                    try await clip.applyLayoutAsync(g)
                    PortDistributor().routeEdges(g)
                    SEBackendContext.recorder?.metrics += given.lastExecutionMetrics + sep.lastExecutionMetrics + loops.lastExecutionMetrics + clip.lastExecutionMetrics
                    fallbacks = given.unroutableEdgeIndices
                } else {
                    try GivenCoordinatesLayoutAlgorithm().applyLayout(g)
                    let router = PolylineEdgeRouter(); router.routeEdges(g)
                    EdgeSeparator().routeEdges(g)
                    SelfLoopRouter().routeEdges(g)
                    EdgeEndpointClipper.clipToNodeBounds(g)
                    PortDistributor().routeEdges(g)
                    fallbacks = g.edges.indices.filter { idx in router.unroutableEdges.contains { $0 === g.edges[idx] } }
                }
                return VisualDrawing(
                    graph: g,
                    fixedCenters: fixedCenters,
                    fallbackEdges: fallbacks,
                    reportedMetrics: ["scaleTier": 2, "pinnedCount": Double(fixedCenters.count), "edgeCount": Double(g.edges.count)],
                    notes: ["42 pinned infrastructure nodes forming a tight corridor maze with cross-grid diagonals, duplicate/reciprocal lanes, and zero obstacle intersections."]
                )
            },

            VisualCase(
                id: "se-multipage-ecosystem-large",
                family: "engineering",
                title: "SE Ecosystem · Large multi-page micro-frontend & service fleet (168 nodes)",
                configuration: ["domain": "ecosystem", "scale": "large", "pipeline": "MultiPage(Hierarchical) → Polyline → EdgeSeparator → SelfLoop → Clip → PortDistributor"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true)
            ) {
                let g = LayoutGraph()
                let componentSizes = [12, 16, 20, 18, 22, 14, 24, 20, 22] // 9 components = 168 nodes
                for (cIdx, count) in componentSizes.enumerated() {
                    var compNodes: [LayoutNode] = []
                    for i in 0..<count {
                        let n = try addLeaf(g, "fleet\(cIdx)-mod\(i)", name: "App\(cIdx)·M\(i)", width: 92 + Double(i % 3) * 12, height: 32)
                        compNodes.append(n)
                        if i > 0 {
                            link(g, compNodes[(i - 1) / 2], n)
                            if i > 3 && i % 3 == 0 { link(g, compNodes[i - 3], n) }
                        }
                    }
                    link(g, compNodes[0], compNodes[0])
                }
                if let ctx = SEBackendContext.active {
                    var hc = HierarchicalLayoutConfiguration(); hc.nodeSeparation = 48; hc.layerSeparation = 90
                    let core = HierarchicalLayoutOperation(backend: ctx.backend, executor: ctx.executor, configuration: hc)
                    let mp = MultiPageLayoutOperation(core, backend: ctx.backend, executor: ctx.executor)
                    mp.pageWidth = 1150; mp.pageHeight = 1020; mp.pageSpacing = 120
                    try await mp.applyLayoutAsync(g)
                    let builder = LayoutBuilder.create(g)
                        .routePolyline(backend: ctx.backend, executor: ctx.executor)
                        .separateEdges(backend: ctx.backend, executor: ctx.executor)
                        .routeSelfLoops(backend: ctx.backend, executor: ctx.executor)
                        .clipEdgeEndpoints(backend: ctx.backend, executor: ctx.executor)
                        .distributePorts(backend: ctx.backend, executor: ctx.executor)
                    try await builder.applyAsync()
                    SEBackendContext.recorder?.metrics += mp.lastExecutionMetrics + builder.lastExecutionMetrics
                } else {
                    let core = HierarchicalLayoutAlgorithm(); core.nodeSeparation = 48; core.layerSeparation = 90
                    let mp = MultiPageLayoutAlgorithm(core)
                    mp.pageWidth = 1150; mp.pageHeight = 1020; mp.pageSpacing = 120
                    try mp.applyLayout(g)
                    PolylineEdgeRouter().routeEdges(g)
                    EdgeSeparator().routeEdges(g)
                    SelfLoopRouter().routeEdges(g)
                    EdgeEndpointClipper.clipToNodeBounds(g)
                    PortDistributor().routeEdges(g)
                }
                return VisualDrawing(
                    graph: g,
                    reportedMetrics: ["scaleTier": 3, "componentCount": 9, "nodeCount": Double(g.nodes.count)],
                    notes: ["Large 168-node multi-page software ecosystem packing 9 disconnected application dependency graphs across 3x3 pages."]
                )
            }
        ]
    }
}
