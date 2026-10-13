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

Built-in layouts, routing, geometry utilities and analysis have async overloads for explicit `.cpu`, `.metal`, and opt-in `.automatic` execution. All 17 presets forward the backend. Existing builder methods without a backend argument retain their CPU behavior. See the [coverage tracker](docs/METAL-PARITY-TRACKER.md) for validation status and the [API guide](docs/METAL-EXECUTION.md) for the operation map.

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

`.metal` reports missing hardware or unsuitable Float precision. `.automatic` uses configurable size/iteration heuristics and can fall back to CPU; unexpected GPU errors still propagate. Inspect `LayoutBuilder.lastExecutionMetrics` or an operation’s `lastMetrics` for the selected backend, CPU/Metal stages and timings. `LayoutExecutor.statistics()` reports resource reuse. Metal arithmetic uses Float or split Float components with exact CPU refinement where required; numerical results can differ from CPU Double results.

See [Metal usage, guarantees and limits](docs/METAL.md). The older `AcceleratedOrganicLayoutAlgorithm` remains a synchronous benchmark API; use the integrated operations above in applications.

## Graph model

- `Point`, `Size`, and `Rect` are `Hashable`, `Codable`, `Sendable` values using `Double` coordinates.
- `LayoutNode`, `LayoutEdge`, and `LayoutGraph` have reference semantics. Node equality and hashing use object identity, independent of the string ID.
- `x` and `y` are the **top-left** corner. Setting `center` preserves the node's size.
- `data: Any?` belongs to the caller. Algorithms never replace it. Analysis results and flags use `metadata: [String: Any]` and `GraphMetadataKeys`.
- `addNode` attaches a parentless node to the invisible root. Use `addGroup(id:parent:frame:)`, `addNode(_:to:)`, and `moveNode(_:to:)` to maintain group ownership and registration together. Manual `parent`/`children` construction remains supported; register both groups and leaves in `graph.nodes`.
- `addNodeDetached` gives temporary subgraphs membership without changing the original hierarchy. Parents are weak references to avoid ownership cycles.
- Use finite coordinates, nonnegative dimensions and unique node references. String IDs should be unique when using ID-based selection, lane or cell assignments.

### Framed groups and nested layouts

Use recursive composition to give each group an independent layout. Frames grow
around their children, internal routes, and measured edge labels. Parent layouts
use the complete frame dimensions and connections between their descendants.

```swift
let graph = LayoutGraph()
let service = try graph.addGroup(id: "Service", frame: GroupFrameOptions(
    headerSize: Size(width: 180, height: 24))) // Measured by your renderer.
let workers = try graph.addGroup(id: "Workers", parent: service, frame: GroupFrameOptions(
    padding: LayoutInsets(top: 16, left: 24, bottom: 24, right: 24),
    headerSize: Size(width: 120, height: 24),
    minimumSize: Size(width: 200, height: 120)))
let first = LayoutNode(id: "first", width: 80, height: 36)
let second = LayoutNode(id: "second", width: 80, height: 36)
try graph.addNode(first, to: workers)
try graph.addNode(second, to: workers)
graph.addEdge(LayoutEdge(source: first, target: second))

try await LayoutBuilder.create(graph)
    .wrapWithRecursiveGroups(HierarchicalLayoutAlgorithm()) { groups in
        groups.groupLayoutSelector = { group in
            if group === workers { return CircularLayoutAlgorithm() }
            return HierarchicalLayoutAlgorithm()
        }
    }
    .clipEdgeEndpoints()
    .applyAsync()

// Draw service.bounds and workers.bounds behind the nodes.
// Draw titles in groupHeaderBounds; groupContentBounds is the usable content area.
```

`GroupFrameOptions` defaults to 20 units of padding on every side, no header,
and zero minimum dimensions. Headers occupy a strip above content; their measured
width can widen the frame. Minimum size includes padding and the header. Empty
groups use the same sizing rules. Groups without explicit options use the
wrapper's `groupPadding`. All output rectangles use world coordinates.

`groupLayoutSelector` runs on the caller's group objects, including the invisible
root, before execution. The core layout is the default when no selector is set.
Child frames appear to layout cores as ordinary sized node proxies. Cores must
preserve topology and may enlarge frames, but shrinking a frame below its measured
size throws an input error. Overlapping sibling frames are separated before their
contents move as rigid units. Ordinary layout calls do not recurse automatically.

Cross-group connections use obstacle-avoiding polylines. They can cross their
containing frames, but avoid unrelated frames and reserved title rectangles.
Usable internal layout paths are retained. The wrappers expose `unroutableEdges`
using original edge identities; failed routes remain visible as direct lines.
Polyline routing does not interpret port constraints. Self-loops supplied by a
core or earlier pipeline step are included when fitting frames.

By default, `optimizeIncomingEdges` refines placement using incoming cross-group
connections and their actual target positions. It tries lateral shifts of frames
and nodes within available content space, preserving frame sizes and sibling
spacing. A move must shorten incoming routes without increasing the total length
of affected routes, escaping a frame, or obstructing another route or title.
Fixed nodes and their containing subtrees are not moved by this refinement.
Set `optimizeIncomingEdges = false` to retain the core placement after frame fitting.
This is a bounded heuristic, not a global minimum-length guarantee.

For async or Metal cores, use `RecursiveGroupLayoutOperation`, or the async/backend
overloads of `wrapWithRecursiveGroups` and `wrapWithFullComposition`; they have the
same configuration closure. Recursive composition commits only when every child
succeeds. Cancellation, invalid output, or frame/hierarchy edits during a suspended
operation discard the result. Hierarchy processing and frame measurement stay on
CPU, as does incoming-edge refinement; selected child layouts and initial routing
retain their backend and metrics.

Rendering and text measurement belong to the caller. This API provides growing
frames, without fixed-size clipping or collapsed groups. If later pipeline steps
move nodes, change labels, or add routes, run recursive layout again to refresh
containment. See the `frames-mixed-layouts`, `frames-large-headers`, and
`frames-obstacle-detour` cases in the visual gallery.

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

Radial, radial-tree, and radial-star layouts account for measured node sizes when
spacing rings and repair routes through unrelated nodes. Configured radial spacing
is a minimum; large nodes can require a larger drawing.

`SubgraphLayoutAlgorithm.avoidUnselectedNodes` defaults to `true`. When necessary,
it translates the selected arrangement, owned paths, and labels as one unit to
clear untouched nodes by ten units. Untouched nodes and unrelated paths remain
exactly fixed. Clearance takes priority over `preserveCentroid`; disable
`avoidUnselectedNodes` to retain the previous centroid-only placement behavior.

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

`OrganicLayoutAlgorithm` defaults to a deterministic quality search with size-aware separation and component packing. Use `OrganicLayoutAlgorithm(quality: .legacy)` (or `OrganicLayoutConfiguration(quality: .legacy)`) for the former force behavior and defaults. Quality mode prioritizes readability over latency; `initialization = .current` restricts candidate starts to supplied positions. See [organic quality controls and diagnostics](docs/ORGANIC.md). It preserves fixed nodes exactly and moves only selected nodes in subset scope. `BarycenterLayoutAlgorithm` also honors fixed nodes; other positioning algorithms can reposition them. Organic layout uses exact pair forces for fewer than 64 nodes and Barnes–Hut repulsion otherwise. Its positions and clustering results are deterministic for a fixed graph order.

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

The routing algorithms follow their distinct Waring contracts:

- **Channel:** `gridSize` sets the actual lattice pitch. Non-group nodes block cells; source/target cells remain accessible. Direction-aware A* charges bend and cell congestion costs, reset per call. Explicit ports sit one unit outside the selected side; candidates are selected greedily by distance. Endpoint doglegs join the lattice.
- **Grouped:** channels come from both endpoint ancestor chains. Shared corridors can nudge leaf nodes when the destination is free, then reroute incident edges. Canonical shared segments receive lane offsets in both traversal directions, followed by boundary trimming. Group nodes stay fixed.
- **BSP:** routes follow bounded partition segments split at their intersections. Nested wrapper cuts extend to the appropriate parent partition, without extending through sibling bodies. By default the outer frame sits `margin` (20) outside the outermost nodes, routes attach through orthogonal side ports (side middles and positions aligned with the other node), A* charges `bendPenalty` (40) per turn, and `EdgeSeparator` spreads shared channels (`edgeSpacing`, 6). An edge with no route through the partition keeps a straight centre-to-centre line and appears in `unroutableEdges`.
- **Polyline:** a straight line when it is clear, otherwise the shortest path over padded obstacle corners, clear of every node body; finished with `EdgeSeparator`.

Only the channel router interprets port constraints and candidates. When no route is found, every router keeps a direct line and lists the edge in `unroutableEdges`; no router returns an empty path. Channel and grouped routing follow the C# reference and do not change clearance or try alternative ports after their initial selection.

`PolylineEdgeRouter` search is deterministic. Padding guides detours; nearby endpoints
can limit the extra clearance beyond node bodies. Its final `EdgeSeparator` pass uses
`edgeSpacing` (default 6; 0 disables it).

`EdgeSeparator` spreads edges that share a collinear stretch, such as duplicates,
reciprocal pairs and shared corridors, into parallel lanes. Lanes keep a consistent side along
consecutive shared stretches, orthogonal routes stay orthogonal, and an edge whose
separated path would cut a node keeps its route. `LayoutBuilder.separateEdges()` adds
it to any pipeline. Presets use it before curve fitting and self-loops; bundling
presets intentionally keep merged tracks. The mode retains the polyline router's endpoint/group exclusions and does not
interpret ports. Clipping remains explicit.

General routers preserve self-loops; route them last with `SelfLoopRouter`, which draws compact orthogonal corner loops (`loopSize`, default 16) on the corner that is clear of other nodes, crosses the fewest routes and is furthest from attached edges; extra loops on a node take other corners, then nest outward. `EdgeEndpointClipper.clipToNodeBounds` trims endpoints along the actual boundary-crossing segments, making it safe to run repeatedly. Most positioning algorithms emit center-to-center paths; clipping is an explicit rendering preparation step.

Bus, octilinear, parallel, bundling and smoothing routers provide visual styles, not obstacle-clearance guarantees. Smoothing and bundling can change a previously obstacle-free route. The hierarchical algorithm already emits bend points for long edges; avoid replacing those paths unless another routing style is intended.

### Labels

Set `edge.labelBounds` to measured dimensions before `LabelLayoutAlgorithm.applyLabelLayout`. For simple text measurement, use `LabelPlacementAlgorithm`: it accepts a `String`, a dictionary with `Label`/`label`, a payload implementing `GraphLabelData`, or a custom `labelProvider` closure. It uses an approximate width of 8 units per character plus 10 units padding.
Both label operations repair node and label collisions with deterministic candidates
along route segments. Label optimization retains its best state and preserves
measured sizes. Crowded drawings can still have unresolved collisions; the visual
evaluator reports them explicitly.

## Tests

Generate a visual gallery of layouts and routing, with PNG/SVG images, geometry
diagnostics, and before/after comparisons:

```sh
swift run graph-layout-visual render --output .build/visual/run-01
open .build/visual/run-01/index.html
```

See [visual evaluation and agent iteration](docs/VISUAL-EVALUATION.md) for case
selection, baselines, comparison commands, and optional Metal cases.

```sh
swift test
swift test --filter GraphPort
swift test --filter RoutingParityTests
```

The port tests exercise geometry, identity and ownership, cycle safety, mixed node sizes, long-edge bends, composition, pins, cancellation, routing, spatial indexes, labels and every preset. Routing parity tests compare 98 fixtures against paths, node bounds and BSP segments generated by the actual C# reference. See [porting notes](docs/PORTING.md) for fidelity boundaries and [routing parity](docs/routing-parity.md) for regeneration instructions. The separately developed `AcceleratedOrganicLayoutAlgorithm` and `graph-layout-benchmark` experiment coexist with the CPU port; see the Metal spike documentation under `docs/`.

## License

SwiftGraph is licensed under the [MIT License](LICENSE).
