import AppKit
import Foundation
import SwiftInterpreter
import SwiftUIBridge
import SwiftUI

// FoodTruckCheck: the PRIMARY TARGET's instrument (LOOP.md). Rung ladder
// per screen, strictly-improving total-rungs score, deterministic, fast.
//
// R0 shell: the merged App+Kit sources interpret and the @main FoodTruckApp
//   scene renders through the app-shell path (its @StateObject model/
//   accountStore seed ContentView — never synthesized stand-ins).
// R1 render: each sidebar panel deep-renders with the app's OWN sample data
//   visible in the tree. Screen probes swap App.swift for a probe app —
//   the same documented divergence as the native twin (@main vs harness
//   main); app sources are READ-ONLY and merge unmodified.
//
// Usage: swift run FoodTruckCheck [--screen substring]

@main
struct FoodTruckCheckMain {
    static func main() throws {
        if ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] == nil {
            var environment = ProcessInfo.processInfo.environment
            environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = Array(CommandLine.arguments.dropFirst())
            process.environment = environment
            try? process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        }

        let sampleRoot = FileManager.default.currentDirectoryPath
            + "/Examples/FoodTruckBuildingASwiftUIMultiplatformApp"

        LiveCheckSupport.traceLifecycle =
            ProcessInfo.processInfo.environment["LIVECHECK_TRACE"] != nil

        var screenFilter: String?
        var captureDirectory: String?
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            if argument == "--screen" { screenFilter = iterator.next() }
            if argument == "--capture" { captureDirectory = iterator.next() }
        }

        // The app + Kit sources; Widgets/ is out of scope (extension process).
        let appFiles = ProjectMaterial.swiftFiles(under: sampleRoot + "/App")
        let kitFiles = ProjectMaterial.swiftFiles(under: sampleRoot + "/FoodTruckKit/Sources")
        guard !appFiles.isEmpty, !kitFiles.isEmpty else {
            print("FoodTruck sample not found at \(sampleRoot)")
            exit(2)
        }

        var rungsPassed = 0
        var rungsTotal = 0
        var failures: [String] = []

        func rung(_ name: String, _ body: () throws -> [String]) {
            rungsTotal += 1
            do {
                let problems = try body()
                if problems.isEmpty {
                    rungsPassed += 1
                    print("✅ \(name)")
                } else {
                    failures.append(contentsOf: problems.map { "\(name): \($0)" })
                    print("❌ \(name)  \(problems.first ?? "")")
                }
            } catch {
                failures.append("\(name): \(error)")
                print("❌ \(name)  threw: \(error)")
            }
        }

        // ── R0: the real @main shell ────────────────────────────────────────────
        let fullMerge = ProjectMaterial.mergedSource(at: sampleRoot, files: appFiles + kitFiles)

        if screenFilter == nil {
            rung("R0-shell") {
                let strings = try LiveCheckSupport.renderedStrings(source: fullMerge)
                var problems: [String] = []
                if !LiveCheckSupport.lastRootSymbol.hasPrefix("scene:FoodTruckApp") {
                    problems.append("root is \(LiveCheckSupport.lastRootSymbol), wanted scene:FoodTruckApp")
                }
                if strings.isEmpty {
                    problems.append("shell rendered no strings")
                }
                return problems
            }
        }

        // ── R1: per-screen renders through a probe app ──────────────────────────
        // Each probe renders DetailColumn with one Panel selection and the model —
        // exactly what ContentView's detail column shows for that sidebar choice.
        struct Screen {
            let name: String
            let panel: String          // the Panel literal in probe source
            let markers: [String]      // app-source-derived strings that must render
        }

        let screens: [Screen] = [
            Screen(name: "truck", panel: ".truck", markers: ["Truck"]),
            Screen(name: "orders", panel: ".orders", markers: ["Orders"]),
            Screen(name: "socialFeed", panel: ".socialFeed", markers: ["Social Feed"]),
            Screen(name: "salesHistory", panel: ".salesHistory", markers: ["Sales History"]),
            Screen(name: "donuts", panel: ".donuts", markers: ["The Classic", "Blueberry Frosted"]),
            Screen(name: "donutEditor", panel: ".donutEditor", markers: ["Donut"]),
            Screen(name: "topFive", panel: ".topFive", markers: ["Top 5 Donuts"]),
            Screen(name: "city", panel: ".city(City.sanFrancisco.id)", markers: ["San Francisco"]),
        ]

        // App.swift swaps for the probe app — the twin's documented divergence.
        let appFilesWithoutMain = appFiles.filter { !$0.hasSuffix("/App/App.swift") }
        let probeMergeBase = ProjectMaterial.mergedSource(
            at: sampleRoot, files: appFilesWithoutMain + kitFiles)

        // ── R2 capture mode: PNG per id, same technique as the twin ──
        if let captureDirectory {
            try? FileManager.default.createDirectory(
                atPath: captureDirectory, withIntermediateDirectories: true)
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)

            @MainActor
            func capturePNG(_ id: String, source: String, size: NSSize) {
                if let screenFilter, !id.localizedCaseInsensitiveContains(screenFilter) { return }
                switch InterpreterHost().render(source: source, lazyTopLevelGlobals: true) {
                case .failure(let error):
                    print("\(id)\tRENDER-FAILED \(error.message.prefix(80))")
                case .success(let view):
                    let hosting = NSHostingView(
                        rootView: view.frame(width: size.width, height: size.height))
                    hosting.frame = NSRect(origin: .zero, size: size)
                    let window = NSWindow(
                        contentRect: hosting.frame, styleMask: .borderless,
                        backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: .aqua)
                    window.contentView = hosting
                    hosting.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    guard let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: max(1, Int(hosting.bounds.width.rounded(.up))),
                        pixelsHigh: max(1, Int(hosting.bounds.height.rounded(.up))),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                        print("\(id)\tREP-NIL")
                        return
                    }
                    rep.size = hosting.bounds.size
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    guard let png = rep.representation(using: .png, properties: [:]) else {
                        print("\(id)\tPNG-NIL")
                        return
                    }
                    let path = captureDirectory + "/\(id).png"
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("\(id)\t\(path)\t\(rep.pixelsWide)x\(rep.pixelsHigh)")
                }
            }

            func probeApp(_ content: String) -> String {
                """

                @main
                struct __FTProbeApp: App {
                    @StateObject private var model = FoodTruckModel()
                    var body: some Scene {
                        WindowGroup {
                            \(content)
                        }
                    }
                }
                """
            }

            let screenSize = NSSize(width: 1000, height: 650)
            let cardSize = NSSize(width: 400, height: 300)
            // Ids and wrappers mirror the twin EXACTLY (main.swift there).
            capturePNG("content", source: fullMerge, size: screenSize)
            capturePNG("truck", source: probeMergeBase + probeApp(
                "TruckView(model: model, navigationSelection: .constant(.truck))"), size: screenSize)
            capturePNG("donuts", source: probeMergeBase + probeApp(
                "DonutGallery(model: model)"), size: screenSize)
            capturePNG("orders", source: probeMergeBase + probeApp(
                "OrdersView(model: model)"), size: screenSize)
            capturePNG("socialfeed", source: probeMergeBase + probeApp(
                "SocialFeedView()"), size: screenSize)
            capturePNG("card-donuts", source: probeMergeBase + probeApp(
                "TruckDonutsCard(donuts: Array(model.donuts.prefix(15))).padding(10).background(Color.white)"), size: cardSize)
            capturePNG("card-orders", source: probeMergeBase + probeApp(
                "TruckOrdersCard(model: model).padding(10).background(Color.white)"), size: cardSize)
            capturePNG("donut-view", source: probeMergeBase + probeApp(
                "DonutView(donut: model.donuts[0]).padding(10).background(Color.white)"), size: cardSize)
            return
        }

        for screen in screens {
            if let screenFilter, !screen.name.localizedCaseInsensitiveContains(screenFilter) { continue }
            rung("R1-\(screen.name)") {
                // "@" + "main" split: SwiftPM's @main scan is textual and would
                // otherwise reclassify this main.swift as a non-main file.
                let probe = """

                @\u{6D}ain
                struct __FTProbeApp: App {
                    @StateObject private var model = FoodTruckModel()
                    @State private var selection: Panel? = \(screen.panel)
                    var body: some Scene {
                        WindowGroup {
                            DetailColumn(selection: $selection, model: model)
                        }
                    }
                }
                """
                let strings = try LiveCheckSupport.renderedStrings(source: probeMergeBase + probe)
                if ProcessInfo.processInfo.environment["FTCHECK_TRACE"] != nil {
                    print("   strings(\(screen.name)): \(strings)")
                }
                var problems: [String] = []
                for marker in screen.markers where !strings.contains(where: { $0.contains(marker) }) {
                    problems.append("missing \"\(marker)\" (rendered \(strings.count) strings)")
                }
                if strings.isEmpty {
                    problems.append("rendered no strings")
                }
                return problems
            }
        }

        print("═══ FoodTruckCheck: \(rungsPassed)/\(rungsTotal) rungs ═══")
        if !failures.isEmpty {
            print("\nfailure classes (fix the biggest first):")
            for failure in failures.prefix(12) {
                print("   \(failure)")
            }
        }

    }
}
