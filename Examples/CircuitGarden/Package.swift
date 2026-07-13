// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CircuitGardenLogic",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CircuitGardenLogic",
            path: ".",
            exclude: ["ContentView.swift", "README.md", "Tests"],
            sources: ["CircuitGame.swift"]
        ),
        .testTarget(
            name: "CircuitGardenLogicTests",
            dependencies: ["CircuitGardenLogic"],
            path: "Tests"
        )
    ]
)
