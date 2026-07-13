// swift-tools-version: 6.2
import PackageDescription

let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

// `-Onone` gives the evaluator's large syntax-dispatch functions 15–20 KB
// stack frames and turns enum/tree dispatch into the dominant cost. That can
// exhaust an iOS main thread's ~1 MB stack and makes data-heavy interpretation
// needlessly slow on macOS. Keep the surrounding app debuggable while compiling
// the execution engine itself with production-quality frames and dispatch.
let interpreterSettings = mainActorByDefault + [
    .unsafeFlags(["-O"], .when(platforms: [.iOS, .macOS], configuration: .debug)),
]

let package = Package(
    name: "DynamicSwiftUI",
    platforms: [.macOS(.v15), .iOS(.v18)],
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
            name: "CheckSupport"
        ),
        .target(
            name: "SwiftInterpreter",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
            ],
            swiftSettings: interpreterSettings
        ),
        .target(
            name: "ObjCExceptionShim"
        ),
        .target(
            name: "SwiftUIBridge",
            dependencies: ["SwiftInterpreter", "ObjCExceptionShim"],
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
            dependencies: ["CheckSupport", "SwiftUIBridge"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "ParityTwin"
        ),
        .executableTarget(
            name: "ParityCheck",
            dependencies: ["CheckSupport", "SwiftUIBridge"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "InterpreterBench",
            dependencies: ["SwiftUIBridge"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "TestCheck",
            dependencies: ["CheckSupport", "SwiftUIBridge"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "LiveCheck",
            dependencies: ["CheckSupport", "SwiftUIBridge"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "FoodTruckCheck",
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
            name: "CheckSupportTests",
            dependencies: ["CheckSupport"]
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
