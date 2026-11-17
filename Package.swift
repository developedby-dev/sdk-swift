// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bydev",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "Bydev", targets: ["Bydev"])
    ],
    targets: [
        .target(name: "Bydev"),
        // 적합성 하네스(sdks/spec/harness-protocol.md) — 실행기가 띄운다
        .executableTarget(name: "BydevConformanceHarness", dependencies: ["Bydev"]),
        .testTarget(name: "BydevTests", dependencies: ["Bydev"]),
    ]
)
