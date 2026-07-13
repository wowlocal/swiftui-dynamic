// swift-tools-version: 6.2
import PackageDescription

let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "AppKitFocusStudio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(
            name: "AppKitFocusStudioNative",
            targets: ["AppKitFocusStudioNative"]
        ),
    ],
    targets: [
        .target(
            name: "AppKitFocusStudio",
            path: "Sources/AppKitFocusStudio",
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "AppKitFocusStudioNative",
            dependencies: ["AppKitFocusStudio"],
            path: "Native",
            swiftSettings: mainActorByDefault
        ),
    ]
)
