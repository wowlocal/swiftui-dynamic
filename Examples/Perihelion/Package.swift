// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Perihelion",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Perihelion", targets: ["Perihelion"]),
    ],
    targets: [
        .executableTarget(
            name: "Perihelion",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
