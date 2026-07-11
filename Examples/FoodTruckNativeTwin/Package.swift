// swift-tools-version:5.9
import PackageDescription

// Native twin of the FoodTruck PRIMARY TARGET: the app's OWN sources
// compiled by swiftc, rendering each screen to PNG via ImageRenderer at a
// fixed size — the ONLY source of pixel/string expectations for
// FoodTruckCheck's R2 rungs (LOOP.md, native-baseline rule).
//
// Kit and App sources are synced VERBATIM by sync.sh (never hand-edited);
// the Kit is compiled as a LOCAL target because its own old-tools
// Package.swift misses the SwiftUI↔AuthenticationServices cross-import
// overlay flag Xcode passes implicitly (ASAuthorizationResult lives there).
let overlays: [SwiftSetting] = [
    .unsafeFlags(["-Xfrontend", "-enable-cross-import-overlays"])
]

let package = Package(
    name: "FoodTruckNativeTwin",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "FoodTruckKit",
            path: "Sources/FoodTruckKit",
            resources: [.process("Assets.xcassets"), .process("Resources")],
            swiftSettings: overlays
        ),
        .executableTarget(
            name: "FoodTruckNativeTwin",
            dependencies: ["FoodTruckKit"],
            path: "Sources/FoodTruckNativeTwin",
            swiftSettings: overlays
        ),
    ]
)
