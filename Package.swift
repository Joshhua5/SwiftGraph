// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftGraph",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftGraph",
            targets: ["SwiftGraph"]
        ),
        .executable(name: "graph-layout-benchmark", targets: ["GraphLayoutBenchmark"]),
        .executable(name: "graph-layout-visual", targets: ["GraphLayoutVisual"]),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SwiftGraph",
            resources: [.copy("Shaders")],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .executableTarget(name: "GraphLayoutBenchmark", dependencies: ["SwiftGraph", "GraphEvaluationSupport"]),
        .target(
            name: "GraphEvaluationSupport",
            dependencies: ["SwiftGraph"],
            path: "Tests",
            exclude: ["SwiftGraphTests"],
            sources: ["Support"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .executableTarget(name: "GraphLayoutVisual", dependencies: ["GraphEvaluationSupport"]),
        .testTarget(
            name: "SwiftGraphTests",
            dependencies: ["SwiftGraph", "GraphEvaluationSupport"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
