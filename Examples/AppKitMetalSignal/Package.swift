// swift-tools-version: 6.2
import PackageDescription

let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "AppKitMetalSignal",
    platforms: [.macOS(.v15)],
    products: [
        .executable(
            name: "AppKitMetalSignalNative",
            targets: ["AppKitMetalSignalNative"]
        ),
    ],
    targets: [
        .target(
            name: "AppKitMetalSignal",
            path: "Sources/AppKitMetalSignal",
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "AppKitMetalSignalNative",
            dependencies: ["AppKitMetalSignal"],
            path: "Native",
            swiftSettings: mainActorByDefault
        ),
        .testTarget(
            name: "AppKitMetalSignalTests",
            dependencies: ["AppKitMetalSignal"],
            path: "Tests/AppKitMetalSignalTests",
            swiftSettings: mainActorByDefault
        ),
    ]
)
