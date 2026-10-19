// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Bob",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Bob", targets: ["Bob"])],
    targets: [
        .target(name: "BobCore", resources: [.process("Resources")]),
        .executableTarget(name: "Bob", dependencies: ["BobCore"]),
        .executableTarget(name: "ComputerUseFixture", path: "Tests/ComputerUseFixture"),
        .testTarget(name: "BobCoreTests", dependencies: ["BobCore", "Bob", "ComputerUseFixture"])
    ]
)
