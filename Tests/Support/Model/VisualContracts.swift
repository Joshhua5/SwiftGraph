import Foundation
import SwiftGraph

struct VisualContracts: Codable, Equatable, Sendable {
    var routesRequired = true
    var noNodeOverlaps = false
    var noObstacleIntersections = false
    var orthogonal = false
    var orthogonalSelfLoops = true
    var expectMissingRoutes = false
    var noLabelOverlaps = false
    var framedGroups = false
}

extension VisualContracts {
    // Early v1 snapshots checked every segment; the later per-loop override defaults to that behavior.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            routesRequired: try c.decode(Bool.self, forKey: .routesRequired),
            noNodeOverlaps: try c.decode(Bool.self, forKey: .noNodeOverlaps),
            noObstacleIntersections: try c.decode(Bool.self, forKey: .noObstacleIntersections),
            orthogonal: try c.decode(Bool.self, forKey: .orthogonal),
            orthogonalSelfLoops: try c.decodeIfPresent(Bool.self, forKey: .orthogonalSelfLoops) ?? true,
            expectMissingRoutes: try c.decode(Bool.self, forKey: .expectMissingRoutes),
            noLabelOverlaps: try c.decodeIfPresent(Bool.self, forKey: .noLabelOverlaps) ?? false,
            framedGroups: try c.decodeIfPresent(Bool.self, forKey: .framedGroups) ?? false
        )
    }
}
