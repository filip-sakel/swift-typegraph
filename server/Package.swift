// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "typegraph-server",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "typegraph-worker", targets: ["typegraph-worker"]),
    .executable(name: "typegraph-gateway", targets: ["typegraph-gateway"]),
  ],
  dependencies: [
    .package(path: "../swift-syntax"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
    .package(url: "https://github.com/apple/swift-system", from: "1.5.0"),
  ],
  targets: [
    // Parse, analyze and export a `TypeGraph` as the JSON wire format (SPEC §3-4).
    .target(
      name: "TypeGraphExport",
      dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
        .product(name: "SwiftDiagnostics", package: "swift-syntax"),
        .product(name: "SwiftIfConfig", package: "swift-syntax"),
        .product(name: "SwiftLexicalLookup", package: "swift-syntax"),
      ]
    ),
    // One job at a time over length-prefixed stdin/stdout (SPEC §5.1).
    .executableTarget(name: "typegraph-worker", dependencies: ["TypeGraphExport"]),
    // Worker pool, scheduling and failure log behind the gateway (SPEC §5.2-5.3).
    .target(
      name: "GatewayCore",
      dependencies: [
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux])),
      ]
    ),
    // HTTP front: validation, worker pool, limits, failure log (SPEC §5).
    .executableTarget(
      name: "typegraph-gateway",
      dependencies: [
        "GatewayCore",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]
    ),
    .testTarget(name: "TypeGraphExportTests", dependencies: ["TypeGraphExport"]),
    // Speaks the worker protocol with scripted behaviour, for GatewayCoreTests.
    .executableTarget(name: "fake-worker", path: "Tests/fake-worker"),
    .testTarget(name: "GatewayCoreTests", dependencies: ["GatewayCore", "fake-worker"]),
  ]
)
