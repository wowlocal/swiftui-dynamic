// swift-tools-version: 6.2
import PackageDescription

let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "DynamicSwiftUI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwiftInterpreter", targets: ["SwiftInterpreter"]),
        .library(name: "SwiftUIBridge", targets: ["SwiftUIBridge"]),
        .executable(name: "DynamicSwiftUIDemo", targets: ["DynamicSwiftUIDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.2"),
    ],
    targets: [
        .target(
            name: "SwiftInterpreter",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
            ],
            swiftSettings: mainActorByDefault
        ),
        .target(
            name: "SwiftUIBridge",
            dependencies: ["SwiftInterpreter"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "DynamicSwiftUIDemo",
            dependencies: ["SwiftUIBridge"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "SpeedBench",
            dependencies: ["SwiftInterpreter"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "ProjectCheck",
            dependencies: ["SwiftUIBridge"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "InterpreterBench",
            dependencies: ["SwiftUIBridge"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "TestCheck",
            dependencies: ["SwiftUIBridge"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "LiveCheck",
            dependencies: ["SwiftUIBridge"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "BridgeGen",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            swiftSettings: mainActorByDefault
        ),
        .testTarget(
            name: "SwiftInterpreterTests",
            dependencies: ["SwiftInterpreter"],
            swiftSettings: mainActorByDefault
        ),
        .testTarget(
            name: "SwiftUIBridgeTests",
            dependencies: ["SwiftUIBridge"],
            exclude: ["Corpus"],
            swiftSettings: mainActorByDefault
        ),
    ]
)
