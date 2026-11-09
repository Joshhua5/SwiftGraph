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
        .library(
            name: "SwiftGraphUI",
            targets: ["SwiftGraphUI"]
        ),
        .executable(name: "graph-layout-benchmark", targets: ["GraphLayoutBenchmark"]),
        .executable(name: "graph-layout-visual", targets: ["GraphLayoutVisual"]),
        .executable(name: "graph-layout-previews", targets: ["GraphLayoutPreviews"]),
        // Separate product so Xcode generates a scheme that can host the gallery's SwiftUI previews.
        .library(name: "GraphLayoutGallery", targets: ["GraphLayoutGallery"]),
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
        .target(
            name: "SwiftGraphUI",
            dependencies: ["SwiftGraph"],
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
        // Example graphs, SwiftUI rendering and previews. A library so Xcode can preview it
        // (executable targets would need ENABLE_DEBUG_DYLIB, which SwiftPM cannot set).
        .target(
            name: "GraphLayoutGallery",
            dependencies: ["SwiftGraph", "SwiftGraphUI"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        // macOS app that hosts the gallery in a window.
        .executableTarget(
            name: "GraphLayoutPreviews",
            dependencies: ["GraphLayoutGallery"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .testTarget(
            name: "SwiftGraphTests",
            dependencies: ["SwiftGraph", "SwiftGraphUI", "GraphEvaluationSupport"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
