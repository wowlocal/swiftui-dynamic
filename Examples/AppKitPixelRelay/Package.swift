// swift-tools-version: 6.2
import PackageDescription

let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "AppKitPixelRelay",
    platforms: [.macOS(.v15)],
    products: [
        .executable(
            name: "AppKitPixelRelayNative",
            targets: ["AppKitPixelRelayNative"]
        ),
    ],
    targets: [
        .target(
            name: "AppKitPixelRelay",
            path: "Sources/AppKitPixelRelay",
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "AppKitPixelRelayNative",
            dependencies: ["AppKitPixelRelay"],
            path: "Native",
            swiftSettings: mainActorByDefault
        ),
    ]
)
