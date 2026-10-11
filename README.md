# SwiftGraph

A native Swift package implementing the layout, routing, analysis, and composition capabilities of `Waring.Core.Graph`. It has no external package dependencies or UI framework dependency. Requires Swift 6.4; the package declares macOS 13 and iOS 16 minimums.

## Quick start

Add the package in Xcode, or add a local dependency to your package manifest:

```swift
.package(path: "../SwiftGraph")
```

Add `SwiftGraph` to your target's dependencies, then:

```swift
import SwiftGraph

let graph = LayoutGraph()
let source = LayoutNode(id: "source", width: 120, height: 50)
let target = LayoutNode(id: "target", width: 120, height: 50)
graph.addNode(source)
graph.addNode(target)
graph.addEdge(LayoutEdge(source: source, target: target))

try await LayoutBuilder.create(graph)
    .useHierarchical {
        $0.nodeSeparation = 80
        $0.layerSeparation = 120
    }
    .routeSelfLoops()
    .clipEdgeEndpoints()
    .applyAsync()

// Read source.bounds, target.bounds and graph.edges[0].path for rendering.
```

For a preset:

```swift
try await LayoutBuilder.create(graph)
    .applyPattern(.enterpriseArchitecture)
    .clipEdgeEndpoints()
    .applyAsync()
```

For direct synchronous use:

```swift
let algorithm = HierarchicalLayoutAlgorithm()
try algorithm.applyLayout(graph)
```

Every `LayoutAlgorithm` also offers `try await algorithm.applyLayoutAsync(graph)`. Existing CPU algorithms use a synchronous default; the builder awaits the protocol's async requirement, and async-only algorithms conform to `AsyncLayoutAlgorithm`. Run expensive synchronous CPU layouts on the caller's chosen background executor. The optional Metal operations below move computation to a reusable executor and suspend while the GPU runs. Mutable graphs, algorithms and builders are intentionally **not Sendable**; confine each graph and its pipeline to one task or actor. The builder executes steps sequentially, checks cancellation between steps, and supports both `transform` and `transformAsync`. A cancelled pipeline is not transactional; completed steps remain applied.

## Metal backend

Organic layout and edge bundling support explicit `.cpu`, `.metal`, and opt-in `.automatic` execution. Existing builder methods without a backend argument retain their CPU behavior.

```swift
let executor = LayoutExecutor() // Reuse across layouts; .shared is also available.

try await LayoutBuilder.create(graph)
    .useOrganic(backend: .metal, executor: executor) {
        $0.iterations = 100
        $0.initialTemperature = 80
    }
    .routeWithBundling(backend: .metal, executor: executor) {
        $0.iterations = 30
        $0.segments = 10
    }
    .routeSelfLoops()
    .clipEdgeEndpoints()
    .applyAsync()
```

Metal execution uses completion handlers, cached pipelines and pooled buffers. Graph objects remain on their owning task/actor; only Sendable geometry snapshots cross to the executor. Cancellation and edits made during a suspended operation discard its result. Fixed and unselected organic nodes preserve their exact coordinates, and bundling preserves endpoint coordinates and self-loop paths.

`.metal` reports missing hardware or unsuitable Float precision. `.automatic` uses configurable size/iteration heuristics and can fall back to CPU; unexpected GPU errors still propagate. To inspect the selected backend and timing, use `OrganicLayoutOperation` or `EdgeBundlingOperation` directly and read `lastMetrics`. `LayoutExecutor.statistics()` reports resource reuse. Metal results use Float and can differ from CPU Double results.

See [Metal usage, guarantees and limits](docs/METAL.md). The older `AcceleratedOrganicLayoutAlgorithm` remains a synchronous benchmark API; use the integrated operations above in applications.

## Graph model

- `Point`, `Size`, and `Rect` are `Hashable`, `Codable`, `Sendable` values using `Double` coordinates.
- `LayoutNode`, `LayoutEdge`, and `LayoutGraph` have reference semantics. Node equality and hashing use object identity, independent of the string ID.
- `x` and `y` are the **top-left** corner. Setting `center` preserves the node's size.
- `data: Any?` belongs to the caller. Algorithms never replace it. Analysis results and flags use `metadata: [String: Any]` and `GraphMetadataKeys`.
- `addNode` attaches a parentless node to the invisible root. To create groups, set a child's `parent` and append it to `parent.children` before adding it to the graph. Register both groups and leaves in `graph.nodes`.
- `addNodeDetached` gives temporary subgraphs membership without changing the original hierarchy. Parents are weak references to avoid ownership cycles.
- Use finite coordinates, nonnegative dimensions and unique node references. String IDs should be unique when using ID-based selection, lane or cell assignments.

## Included algorithms

| Family | Types |
| --- | --- |
| Hierarchical | `HierarchicalLayoutAlgorithm`, `SeriesParallelLayoutAlgorithm` |
| Organic and refinement | `OrganicLayoutAlgorithm`, `BarycenterLayoutAlgorithm`, `RemoveOverlapsLayoutAlgorithm` |
| Tree and radial | `TreeLayoutAlgorithm`, `RadialTreeLayoutAlgorithm`, `BalloonLayoutAlgorithm`, `RadialLayoutAlgorithm`, `RadialStarLayoutAlgorithm`, `OrgChartLayoutAlgorithm` |
| Grid and packing | `OrthogonalLayoutAlgorithm`, `PartitionGridLayoutAlgorithm`, `TabularLayoutAlgorithm`, `KandinskyLayoutAlgorithm`, `CircularLayoutAlgorithm`, `CompactDiskLayoutAlgorithm`, `VerticalStackLayoutAlgorithm` |
| Specialized | `SwimlaneLayoutAlgorithm`, `TreeMapLayoutAlgorithm`, `AlignmentLayoutAlgorithm`, `FillAreaLayoutAlgorithm`, `ClearAreaLayoutAlgorithm`, `GivenCoordinatesLayoutAlgorithm` |
| Composition | `ComponentLayout`, `MultiPageLayoutAlgorithm`, `RecursiveGroupLayout`, `SubgraphLayoutAlgorithm` |
| Analysis | `PageRankAlgorithm`, `LabelPropagationClusteringAlgorithm` (deprecated `LouvainClusteringAlgorithm` alias) |
| Labels | `LabelPlacementAlgorithm`, `LabelLayoutAlgorithm` |

All 17 `LayoutPatternType` presets are available. Builder extensions also include grain swimlanes, importance-based and cluster-based layouts, routing suffixes and explicit composition helpers.

### Pinned nodes and analysis

```swift
source.metadata[GraphMetadataKeys.fixed] = true

target.metadata[GraphMetadataKeys.layoutSubset] = true
let organic = OrganicLayoutAlgorithm()
organic.scope = .subset
try organic.applyLayout(graph)

try PageRankAlgorithm().applyLayout(graph)
let score = target.metadata[GraphMetadataKeys.pageRank] as? Double
```

`OrganicLayoutAlgorithm` preserves fixed nodes exactly and moves only selected nodes in subset scope. `BarycenterLayoutAlgorithm` also honors fixed nodes; other positioning algorithms can reposition them. Organic layout uses exact pair forces for fewer than 64 nodes and Barnes–Hut repulsion otherwise. Its positions and clustering results are deterministic for a fixed graph order.

## Routing

`PolylineEdgeRouter`, `ChannelEdgeRouter`, `BspEdgeRouter`, `OrthogonalGroupedEdgeRouter`, `BusEdgeRouter`, `OctilinearEdgeRouter`, `ParallelEdgeRouter`, `EdgeBundlingRouter`, `CurveFittingEdgeRouter`, and `SelfLoopRouter` implement `EdgeRouter`.

```swift
let edge = graph.edges[0]
edge.sourcePort = .right
edge.targetPortCandidates = [.top, .left]
let router = ChannelEdgeRouter()
router.routeEdges(graph)
let failures = router.unroutableEdges
```

Channel, BSP, grouped and polyline routers expose `unroutableEdges`. An impossible route gets an empty path rather than an unchecked line through an obstacle. They try allowed endpoint sides and relax preferred clearance when a narrower valid route exists. Ports and port candidates are honored by these routers. Hierarchical layout itself does not consume port constraints.

General routers preserve self-loops; route them last with `SelfLoopRouter`. `EdgeEndpointClipper.clipToNodeBounds` trims endpoints along the actual boundary-crossing segments, making it safe to run repeatedly. Most positioning algorithms emit center-to-center paths; clipping is an explicit rendering preparation step.

Bus, octilinear, parallel, bundling and smoothing routers provide visual styles, not obstacle-clearance guarantees. Smoothing and bundling can change a previously obstacle-free route. The hierarchical algorithm already emits bend points for long edges; avoid replacing those paths unless another routing style is intended.

### Labels

Set `edge.labelBounds` to measured dimensions before `LabelLayoutAlgorithm.applyLabelLayout`. For simple text measurement, use `LabelPlacementAlgorithm`: it accepts a `String`, a dictionary with `Label`/`label`, a payload implementing `GraphLabelData`, or a custom `labelProvider` closure. It uses an approximate width of 8 units per character plus 10 units padding.

## Tests

```sh
swift test
swift test --filter GraphPort
```

The port tests exercise geometry, identity and ownership, cycle safety, mixed node sizes, long-edge bends, composition, pins, cancellation, routing, spatial indexes, labels and every preset. See [porting notes](docs/PORTING.md) for fidelity boundaries. The separately developed `AcceleratedOrganicLayoutAlgorithm` and `graph-layout-benchmark` experiment coexist with the CPU port; see the Metal spike documentation under `docs/`.
