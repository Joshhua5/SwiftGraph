// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "MetalBackendBenchmark", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "Benchmark", dependencies: [.product(name: "SwiftGraph", package: "SwiftGraph")])]
)
