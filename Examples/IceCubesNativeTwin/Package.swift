// swift-tools-version: 6.2
import PackageDescription

// Native Catalyst twin for LOOP-ICECUBES.md. It compiles IceCubes' real local
// packages and drives their public Mastodon client through a fail-closed replay
// URLProtocol. Build via build.sh: SwiftPM needs the Catalyst SDK search paths
// explicitly when producing a command-line executable rather than an app.
let iceCubes = "../../External/oss/IceCubesApp/Packages"

let package = Package(
    name: "IceCubesNativeTwin",
    platforms: [.iOS(.v18)],
    dependencies: [
        .package(name: "Account", path: "\(iceCubes)/Account"),
        .package(name: "AppAccount", path: "\(iceCubes)/AppAccount"),
        .package(name: "DesignSystem", path: "\(iceCubes)/DesignSystem"),
        .package(name: "Env", path: "\(iceCubes)/Env"),
        .package(name: "Explore", path: "\(iceCubes)/Explore"),
        .package(name: "MediaUI", path: "\(iceCubes)/MediaUI"),
        .package(name: "Models", path: "\(iceCubes)/Models"),
        .package(name: "NetworkClient", path: "\(iceCubes)/NetworkClient"),
        .package(name: "StatusKit", path: "\(iceCubes)/StatusKit"),
        .package(name: "Timeline", path: "\(iceCubes)/Timeline"),
        .package(url: "https://github.com/kean/Nuke", exact: "12.8.0"),
    ],
    targets: [
        // IceCubes' APP TARGET sources. SwiftPM refuses a target `path` that
        // escapes the package root, so each admitted app file is symlinked
        // into this target's directory — one link per file, so the directory
        // listing IS the list of app sources the twin compiles and SwiftPM has
        // no unhandled files to warn about. `AppTargetScreens.swift` is
        // compiled into the same module, which is what lets it expose the
        // app's `internal` screens without editing an app file. Screens join
        // one at a time because the app target as a whole needs RevenueCat,
        // WishKit and AppIntents. See AppTargetScreens.swift.
        .target(
            name: "IceCubesAppTarget",
            dependencies: [
                .product(name: "Account", package: "Account"),
                .product(name: "DesignSystem", package: "DesignSystem"),
                .product(name: "Models", package: "Models"),
                .product(name: "NukeUI", package: "Nuke"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "IceCubesNativeTwin",
            dependencies: [
                "IceCubesAppTarget",
                .product(name: "Account", package: "Account"),
                .product(name: "AppAccount", package: "AppAccount"),
                .product(name: "DesignSystem", package: "DesignSystem"),
                .product(name: "Env", package: "Env"),
                .product(name: "Explore", package: "Explore"),
                .product(name: "MediaUI", package: "MediaUI"),
                .product(name: "Models", package: "Models"),
                .product(name: "NetworkClient", package: "NetworkClient"),
                .product(name: "StatusKit", package: "StatusKit"),
                .product(name: "Timeline", package: "Timeline"),
                .product(name: "Nuke", package: "Nuke"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        )
    ]
)
