import Foundation

extension DirectedLayoutConfiguration {
    func validateExecution() throws {
        guard canvasAspectRatio.isFinite,
            [nodeSpacing, layerSpacing, componentSpacing, portSpacing, clearance, edgeSpacing].allSatisfy(\.isFinite),
            edgeWidths.allSatisfy(\.isFinite),
            previousBounds.values.allSatisfy({
                [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width >= 0 && $0.height >= 0
            }),
            insertionOrigins.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
            previousPaths.values.allSatisfy({ $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } })
        else {
            throw LayoutExecutionError.invalidInput("Directed configuration requires finite geometry.")
        }
    }
}
