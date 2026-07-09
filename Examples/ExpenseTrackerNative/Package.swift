// swift-tools-version:5.9
import PackageDescription

// Native twin of Examples/ExpenseTracker: the same four source files compiled
// by swiftc instead of interpreted. `swift run` here, or `xed .` for Xcode.
let package = Package(
    name: "ExpenseTrackerNative",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ExpenseTrackerNative", path: "Sources")
    ]
)
