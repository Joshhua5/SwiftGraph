// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MetalReview",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "Review", dependencies: [
            .product(name: "SwiftGraph", package: "SwiftGraph")
        ])
    ]
)
