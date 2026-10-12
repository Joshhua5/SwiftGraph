using System.Text.Json;
using System.Text.Json.Nodes;
using Waring.Core.Graph;
using Waring.Core.Graph.EdgeRouter;

// Generate golden routing results by compiling the actual reference files, without modifying them.
var cases = JsonNode.Parse(File.ReadAllText(args[0]))!.AsArray();
foreach (var item in cases) {
    var test = item!.AsObject();
    var graph = new LayoutGraph();
    var nodes = new Dictionary<string, LayoutNode>();
    foreach (var entry in test["nodes"]!.AsArray()) {
        var bounds = entry!["bounds"]!.AsArray().Select(v => v!.GetValue<double>()).ToArray();
        var node = new LayoutNode(entry["id"]!.GetValue<string>(), bounds[2], bounds[3]) {
            X = bounds[0], Y = bounds[1], IsGroup = entry["group"]?.GetValue<bool>() ?? false
        };
        nodes[node.Id] = node;
    }
    foreach (var entry in test["nodes"]!.AsArray()) {
        var node = nodes[entry!["id"]!.GetValue<string>()];
        if (entry["parent"] is { } parent) {
            node.Parent = nodes[parent.GetValue<string>()];
            node.Parent.Children.Add(node);
        }
        graph.AddNode(node);
    }
    foreach (var entry in test["edges"]!.AsArray()) {
        var edge = new LayoutEdge(nodes[entry!["source"]!.GetValue<string>()], nodes[entry["target"]!.GetValue<string>()]);
        if (entry["sourcePort"] is { } sp) edge.SourcePort = Enum.Parse<PortConstraint>(sp.GetValue<string>(), true);
        if (entry["targetPort"] is { } tp) edge.TargetPort = Enum.Parse<PortConstraint>(tp.GetValue<string>(), true);
        if (entry["sourceCandidates"] is JsonArray sc) edge.SourcePortCandidates = sc.Select(v => Enum.Parse<PortConstraint>(v!.GetValue<string>(), true)).ToList();
        if (entry["targetCandidates"] is JsonArray tc) edge.TargetPortCandidates = tc.Select(v => Enum.Parse<PortConstraint>(v!.GetValue<string>(), true)).ToList();
        if (entry["path"] is JsonArray path) edge.Path = path.Select(v => new Point(v![0]!.GetValue<double>(), v[1]!.GetValue<double>())).ToList();
        graph.AddEdge(edge);
    }
    double Config(string key, double fallback) => test["config"]?[key]?.GetValue<double>() ?? fallback;
    IEdgeRouter router = test["router"]!.GetValue<string>() switch {
        "channel" => new ChannelEdgeRouter { GridSize = (int)Config("gridSize", 20), BendPenalty = (int)Config("bendPenalty", 2), CongestionPenalty = (int)Config("congestionPenalty", 2) },
        "grouped" => new OrthogonalGroupedEdgeRouter { BundleSpacing = Config("bundleSpacing", 4), ObstacleMargin = Config("obstacleMargin", 10), BendPenalty = Config("bendPenalty", 100) },
        "bsp" => new BspEdgeRouter(),
        "polyline" => new PolylineEdgeRouter { Padding = Config("padding", 10) },
        _ => throw new ArgumentException("Unknown router")
    };
    var calculator = new BspGridCalculator();
    calculator.BuildTree(graph);
    double[] PointArray(Point point) => [point.X, point.Y];
    double[] BoundsArray(Rect bounds) => [bounds.X, bounds.Y, bounds.Width, bounds.Height];
    var global = calculator.GetGlobalGridSegments().Select(s => new[] { PointArray(s.Start), PointArray(s.End) }).ToArray();
    var local = graph.Nodes.Select(n => calculator.GetLocalGridSegments(n).Select(s => new[] { PointArray(s.Start), PointArray(s.End) }).ToArray()).ToArray();
    router.RouteEdges(graph);
    test["expected"] = JsonSerializer.SerializeToNode(new {
        paths = graph.Edges.Select(e => e.Path.Select(PointArray).ToArray()).ToArray(),
        bounds = graph.Nodes.Select(n => BoundsArray(n.Bounds)).ToArray(),
        root = BoundsArray(graph.Root.Bounds), global, local
    });
}
File.WriteAllText(args[1], cases.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
