import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// SCRATCH bisect harness for the editor-blank hunt: which merged app file
// makes `Form { Section { Text } }.formStyle(.grouped)` inside HSplitView
// stop rendering? Binary-searches the app file list. (Deleted once the
// culprit is pinned.)
@Suite struct MergeBisectScratchTests {
    @MainActor
    @Test func bisectMergedFileThatBlanksSplitForm() throws {
        let root = FileManager.default.currentDirectoryPath
            + "/Examples/FoodTruckBuildingASwiftUIMultiplatformApp"
        let appFiles = ProjectMaterial.swiftFiles(under: root + "/App")
            .filter { !$0.hasSuffix("/App/App.swift") }
        let kitFiles = ProjectMaterial.swiftFiles(under: root + "/FoodTruckKit/Sources")

        let clockShim = """

        extension Date {
            static var now: Date {
                if let raw = ProcessInfo.processInfo.environment["FOODTRUCK_FROZEN_NOW"],
                   let epoch = TimeInterval(raw) {
                    return Date(timeIntervalSince1970: epoch)
                }
                return Date(timeIntervalSinceNow: 0)
            }
        }
        """

        let probeBody = clockShim + """

        @main
        struct __BisectApp: App {
            @StateObject private var model = FoodTruckModel()
            var body: some Scene {
                WindowGroup {
                    HSplitView {
                        Text(String("LEFT")).frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                        Form { Section(String("Head")) { Text(String("RIGHT MARKER")) } }
                            .formStyle(.grouped)
                            .padding()
                            .frame(minWidth: 300, idealWidth: 350, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
        """

        let previousPlatform = Interpreter.interpretsAsPlatform
        Interpreter.interpretsAsPlatform = "macOS"
        defer { Interpreter.interpretsAsPlatform = previousPlatform }

        @MainActor func rightInk(files: [String]) -> Int {
            let source = ProjectMaterial.mergedSource(at: root, files: files) + probeBody
            guard case .success(let view) = InterpreterHost().render(
                source: source, lazyTopLevelGlobals: true) else { return -1 }
            let size = NSSize(width: 700, height: 300)
            let hosting = NSHostingView(
                rootView: view.frame(width: size.width, height: size.height)
                    .background(Color.white))
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: hosting.frame, styleMask: .borderless,
                backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return -2 }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            var ink = 0
            for x in 350..<700 { for y in 0..<300 {
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.88 { ink += 1 }
            } }
            return ink
        }

        let none = rightInk(files: [])
        let full = rightInk(files: appFiles + kitFiles)
        print("BISECT baseline none=\(none) full=\(full)")
        guard none > 50, full <= 50 else {
            print("BISECT preconditions not met — no bisect")
            return
        }
        // Bisect over the app+kit list: find one culprit file.
        var candidates = appFiles + kitFiles
        var stable: [String] = []
        while candidates.count > 1 {
            let half = Array(candidates.prefix(candidates.count / 2))
            let rest = Array(candidates.dropFirst(candidates.count / 2))
            if rightInk(files: stable + half) <= 50 {
                candidates = half
            } else {
                stable += half
                candidates = rest
            }
        }
        print("BISECT culprit:", candidates.first ?? "none",
              "confirm:", rightInk(files: stable + candidates))
    }
}
