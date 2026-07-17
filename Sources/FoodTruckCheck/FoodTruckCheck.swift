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

        // The twin is a macOS build — interpret the app the same way.
        Interpreter.interpretsAsPlatform = "macOS"
        LiveCheckSupport.traceLifecycle =
            ProcessInfo.processInfo.environment["LIVECHECK_TRACE"] != nil

        var screenFilter: String?
        var captureDirectory: String?
        var scenarioFilter: String?
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            if argument == "--screen" { screenFilter = iterator.next() }
            if argument == "--capture" { captureDirectory = iterator.next() }
            if argument == "--scenario" { scenarioFilter = iterator.next() }
        }

        // Harness frozen clock — the SAME shim the twin's sync.sh generates
        // (one copy: the merge is a single module). Env-gated; without
        // FOODTRUCK_FROZEN_NOW behavior is native-identical.
        let frozenClockShim = """

        extension Date {
            static var now: Date {
                if let raw = ProcessInfo.processInfo.environment["FOODTRUCK_FROZEN_NOW"],
                   let epoch = TimeInterval(raw) {
                    return Date(timeIntervalSince1970: epoch)
                }
                return Date(timeIntervalSinceNow: 0)
            }
        }

        // Deterministic `.random` for harness runs — same doctrine as the
        // frozen clock. Env-pinned runs draw from a shared LCG so twin and
        // interpreter social-feed timestamps agree bit-exactly; unpinned
        // (live) runs seed from the wall clock so launches still differ.
        // The seeded `.random(in:using:)` spellings resolve past this shadow
        // to the stdlib, exactly like native overload resolution.
        nonisolated(unsafe) var __harnessRandomState = 0
        extension Double {
            static func random(in range: ClosedRange<Double>) -> Double {
                if __harnessRandomState == 0 {
                    if ProcessInfo.processInfo.environment["FOODTRUCK_FROZEN_NOW"] != nil {
                        __harnessRandomState = 1
                    } else {
                        __harnessRandomState = Int(Date(timeIntervalSinceNow: 0).timeIntervalSince1970 * 1000) % 2147483647 + 1
                    }
                }
                __harnessRandomState = (__harnessRandomState * 1103515245 + 12345) % 2147483648
                let unit = Double(__harnessRandomState) / 2147483648.0
                return range.lowerBound + unit * (range.upperBound - range.lowerBound)
            }
        }
        """

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
            + frozenClockShim

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
            at: sampleRoot, files: appFilesWithoutMain + kitFiles) + frozenClockShim
        if let dumpPath = ProcessInfo.processInfo.environment["FTCHECK_DUMP_MERGE"] {
            try? probeMergeBase.write(toFile: dumpPath, atomically: true, encoding: .utf8)
        }

        // ── R2 capture mode: PNG per id, same technique as the twin ──
        if let captureDirectory {
            try? FileManager.default.createDirectory(
                atPath: captureDirectory, withIntermediateDirectories: true)
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)

            @MainActor
            func capturePNG(_ id: String, source: String, size: NSSize) {
                if let screenFilter, !id.localizedCaseInsensitiveContains(screenFilter) { return }
                RenderDiagnostics.reset()
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
                    for entry in RenderDiagnostics.errors.prefix(12) {
                        print("   ⚠ \(id) \(entry.view): \(entry.error.message.prefix(110))")
                    }
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

            // ── R3 scenarios (Scripts/foodtruck-r3-spec.md): mutate through
            // the model's OWN public API, re-capture. Declarations, mutation
            // calls, and capture ids mirror the twin's runScenarios exactly.
            if let scenarioFilter {
                struct ScenarioCapture {
                    let id: String
                    let content: String
                    let size: NSSize
                }
                struct Scenario {
                    let name: String
                    let declaration: String
                    let captures: [ScenarioCapture]
                }

                func scenarioApp(_ content: String) -> String {
                    """

                    @main
                    struct __FTProbeApp: App {
                        var body: some Scene {
                            WindowGroup {
                                \(content)
                            }
                        }
                    }
                    """
                }

                let scenarios: [Scenario] = [
                    Scenario(
                        name: "donut-rename",
                        declaration: """

                        final class __FTScenario {
                            let model: FoodTruckModel
                            let renamedID: Donut.ID
                            init() {
                                let model = FoodTruckModel()
                                var donut = model.donuts[0]
                                let id = donut.id
                                donut.name = "Parity Deluxe"
                                model.updateDonut(id: id, to: donut)
                                self.model = model
                                self.renamedID = id
                            }
                        }
                        let __scenario = __FTScenario()
                        """,
                        captures: [
                            ScenarioCapture(
                                id: "donuts-after-rename",
                                content: "DonutGallery(model: __scenario.model)",
                                size: NSSize(width: 1000, height: 650)),
                            ScenarioCapture(
                                id: "donut-view-after-rename",
                                content: "DonutView(donut: __scenario.model.donut(id: __scenario.renamedID)).padding(10).background(Color.white)",
                                size: NSSize(width: 400, height: 300)),
                        ]),
                    Scenario(
                        name: "order-completes",
                        declaration: """

                        final class __FTScenario {
                            let model: FoodTruckModel
                            init() {
                                let model = FoodTruckModel()
                                if let first = model.orders.first(where: { !$0.isComplete }) {
                                    model.markOrderAsCompleted(id: first.id)
                                }
                                self.model = model
                            }
                        }
                        let __scenario = __FTScenario()
                        """,
                        captures: [
                            ScenarioCapture(
                                id: "orders-after-complete",
                                content: "OrdersView(model: __scenario.model)",
                                size: NSSize(width: 1000, height: 650)),
                        ]),
                    Scenario(
                        name: "order-steps-preparing",
                        declaration: """

                        final class __FTScenario {
                            let model: FoodTruckModel
                            init() {
                                let model = FoodTruckModel()
                                if let first = model.orders.first(where: { !$0.isComplete }) {
                                    let binding = model.orderBinding(for: first.id)
                                    binding.wrappedValue.markAsPreparing()
                                }
                                self.model = model
                            }
                        }
                        let __scenario = __FTScenario()
                        """,
                        captures: [
                            ScenarioCapture(
                                id: "orders-after-preparing",
                                content: "OrdersView(model: __scenario.model)",
                                size: NSSize(width: 1000, height: 650)),
                        ]),
                    Scenario(
                        name: "order-steps",
                        declaration: """

                        final class __FTScenario {
                            let model: FoodTruckModel
                            init() {
                                let model = FoodTruckModel()
                                if let first = model.orders.first(where: { !$0.isComplete }) {
                                    let binding = model.orderBinding(for: first.id)
                                    binding.wrappedValue.markAsPreparing()
                                    binding.wrappedValue.markAsComplete()
                                }
                                self.model = model
                            }
                        }
                        let __scenario = __FTScenario()
                        """,
                        captures: [
                            ScenarioCapture(
                                id: "orders-after-steps",
                                content: "OrdersView(model: __scenario.model)",
                                size: NSSize(width: 1000, height: 650)),
                        ]),
                    Scenario(
                        name: "popularity-moves",
                        declaration: """

                        final class __FTScenario {
                            let model: FoodTruckModel
                            init() {
                                let model = FoodTruckModel()
                                for order in model.orders where !order.isComplete {
                                    model.markOrderAsCompleted(id: order.id)
                                }
                                self.model = model
                            }
                        }
                        let __scenario = __FTScenario()
                        """,
                        captures: [
                            ScenarioCapture(
                                id: "donuts-after-popularity",
                                content: "DonutGallery(model: __scenario.model)",
                                size: NSSize(width: 1000, height: 650)),
                            ScenarioCapture(
                                id: "card-donuts-after-popularity",
                                content: "TruckDonutsCard(donuts: Array(__scenario.model.donuts(sortedBy: .popularity(.month)).prefix(15))).padding(10).background(Color.white)",
                                size: NSSize(width: 400, height: 300)),
                        ]),
                    Scenario(
                        name: "nav-selection",
                        declaration: """

                        final class __FTScenario {
                            let model: FoodTruckModel
                            init() {
                                self.model = FoodTruckModel()
                            }
                        }
                        let __scenario = __FTScenario()
                        """,
                        captures: [
                            ScenarioCapture(
                                id: "detail-truck",
                                content: "DetailColumn(selection: .constant(.truck), model: __scenario.model)",
                                size: NSSize(width: 1000, height: 650)),
                            ScenarioCapture(
                                id: "detail-orders",
                                content: "DetailColumn(selection: .constant(.orders), model: __scenario.model)",
                                size: NSSize(width: 1000, height: 650)),
                            ScenarioCapture(
                                id: "detail-donuts",
                                content: "DetailColumn(selection: .constant(.donuts), model: __scenario.model)",
                                size: NSSize(width: 1000, height: 650)),
                        ]),
                ]

                for scenario in scenarios {
                    if scenarioFilter != "all", scenario.name != scenarioFilter { continue }
                    for capture in scenario.captures {
                        capturePNG(
                            capture.id,
                            source: probeMergeBase + scenario.declaration + scenarioApp(capture.content),
                            size: capture.size)
                    }
                }
                return
            }

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
            capturePNG("diag-navlink", source: probeMergeBase + probeApp(
                "NavigationLink(value: Panel.orders) { Label(String(\"New Orders\"), systemImage: String(\"shippingbox\")) }.background(Color.white)"), size: cardSize)
            capturePNG("diag-label", source: probeMergeBase + probeApp(
                "Label(String(\"New Orders\"), systemImage: String(\"shippingbox\")).background(Color.white)"), size: cardSize)
            capturePNG("diag-labelstyle", source: probeMergeBase + probeApp(
                "Label(String(\"New Orders\"), systemImage: String(\"shippingbox\")).labelStyle(.cardNavigationHeader).background(Color.white)"), size: cardSize)
            capturePNG("diag-cardheader", source: probeMergeBase + probeApp(
                "VStack { CardNavigationHeader(panel: Panel.orders, navigation: .navigationLink) { Label(String(\"New Orders\"), systemImage: String(\"shippingbox\")) } }.frame(width: 380, height: 60).background(Color.white)"), size: cardSize)
            let diagChartDecl = """

            struct __ChartProbe: View {
                var body: some View {
                    Chart {
                        marks()
                            .foregroundStyle(.linearGradient(colors: [.teal, .yellow], startPoint: .bottom, endPoint: .top))
                    }
                }
                @ChartContentBuilder
                func marks() -> some ChartContent {
                    labeled(seriesKey: String("S"), value: 0)
                }
                struct __Entry: Identifiable {
                    var id: Date { date }
                    var date: Date
                    var degrees: Double
                }
                var entries: [__Entry] {
                    [__Entry(date: Date(timeIntervalSince1970: 1784220000), degrees: 63),
                     __Entry(date: Date(timeIntervalSince1970: 1784223600), degrees: 72),
                     __Entry(date: Date(timeIntervalSince1970: 1784227200), degrees: 80)]
                }
                @ChartContentBuilder
                func labeled(seriesKey: String, value: Double) -> some ChartContent {
                    ForEach(entries) { entry in
                        AreaMark(
                            x: .value(String("Hour"), entry.date),
                            yStart: .value(String("Temperature"), 55.0),
                            yEnd: .value(String("Temperature"), entry.degrees),
                            series: .value(seriesKey, value)
                        )
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
            """
            capturePNG("diag-forecast-data", source: probeMergeBase + probeApp(
                "VStack { Text(String(TruckWeatherCard.placeholderForecast.entries.count)); Text(String(TruckWeatherCard.placeholderForecast.nightTimeRanges.count)); Text(String(TruckWeatherCard.placeholderForecast.low)) }.font(.system(size: 40)).background(Color.white)"), size: cardSize)
            capturePNG("diag-sales", source: probeMergeBase + probeApp(
                "Text(model.dailyOrderSummaries(cityID: City.cupertino.id).first!.sales.sorted { $0.key < $1.key }.map { String(describing: $0.key) + String(\":\") + String(describing: $0.value) }.joined(separator: String(\",\"))).font(.system(size: 14)).background(Color.white)"), size: cardSize)
            capturePNG("diag-weather", source: probeMergeBase + probeApp(
                "TruckWeatherCard(location: CLLocation(latitude: 37.3, longitude: -122.0)).padding(10).background(Color.white)"), size: cardSize)
            let diagAnnotationDecl = """

            struct __AnnotationProbe: View {
                var body: some View {
                    Chart {
                        RectangleMark(
                            x: .value(String("X"), 1.0),
                            yStart: .value(String("Y"), 0.0),
                            yEnd: .value(String("Y"), 5.0),
                            width: .fixed(6)
                        )
                        .annotation(position: .top, alignment: .bottom, spacing: 5) {
                            Image(systemName: String("moon.circle.fill"))
                                .imageScale(.large)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .indigo)
                        }
                    }
                }
            }
            """
            let diagSymbolDecl = """

            struct __SymbolProbe: View {
                var body: some View {
                    HStack(spacing: 20) {
                        Image(systemName: String("moon.circle.fill"))
                            .imageScale(.large)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .indigo)
                        Image(systemName: String("moon.circle.fill"))
                            .imageScale(.large)
                            .foregroundStyle(.indigo)
                        Image(systemName: String("moon.circle.fill"))
                            .imageScale(.large)
                            .symbolRenderingMode(.multicolor)
                    }
                }
            }
            """
            let diagAxisDecl = """

            struct __AxisProbe: View {
                var range: ClosedRange<Date> {
                    let start = Date(timeIntervalSince1970: 1784192400)
                    return start...start.addingTimeInterval(24 * 3600)
                }
                var body: some View {
                    Chart {
                        LineMark(
                            x: .value(String("Date"), range.lowerBound),
                            y: .value(String("Temperature"), 55.0)
                        )
                        LineMark(
                            x: .value(String("Date"), range.upperBound),
                            y: .value(String("Temperature"), 85.0)
                        )
                    }
                    .chartXAxis {
                        AxisMarks(values: DateBins(unit: .hour, by: 3, range: range).thresholds) { _ in
                            AxisValueLabel(format: .dateTime.hour())
                            AxisTick()
                            AxisGridLine()
                        }
                    }
                }
            }
            """
            capturePNG("diag-axis", source: probeMergeBase + diagAxisDecl + probeApp(
                "__AxisProbe().frame(width: 400, height: 200).background(Color.white)"), size: cardSize)
            capturePNG("diag-symbol", source: probeMergeBase + diagSymbolDecl + probeApp(
                "__SymbolProbe().frame(width: 200, height: 80).background(Color.gray)"), size: cardSize)
            capturePNG("diag-annotation", source: probeMergeBase + diagAnnotationDecl + probeApp(
                "__AnnotationProbe().frame(width: 200, height: 150).background(Color.white)"), size: cardSize)
            capturePNG("diag-chart", source: probeMergeBase + diagChartDecl + probeApp(
                "__ChartProbe().frame(width: 300, height: 200).background(Color.white)"), size: cardSize)
            capturePNG("diag-layout", source: probeMergeBase + probeApp(
                "DonutStackView(donuts: Array(model.donuts.prefix(3))).frame(width: 120, height: 120).background(Color.white)"), size: cardSize)
            let diagMiniLayoutDecl = """

            struct __MiniLayout: Layout {
                func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
                    return CGSize(width: 120, height: 120)
                }
                func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
                    for index in subviews.indices {
                        subviews[index].place(
                            at: CGPoint(x: bounds.minX + 10, y: bounds.minY + Double(index) * 30 + 10),
                            anchor: .topLeading,
                            proposal: ProposedViewSize(width: 60, height: 20))
                    }
                }
            }
            """
            capturePNG("diag-minilayout", source: probeMergeBase + diagMiniLayoutDecl + probeApp(
                "__MiniLayout { Text(String(\"aa\")); Text(String(\"bb\")) }.background(Color.white)"), size: cardSize)
            // Bisect probes (diag-*): not compared by the AE board — pure
            // diagnosis rungs for blank screens.
            capturePNG("diag-grid", source: probeMergeBase + probeApp(
                "ScrollView { DonutGalleryGrid(donuts: model.donuts, width: 1000) }.background(Color.white)"), size: screenSize)
            capturePNG("diag-table", source: probeMergeBase + probeApp(
                "OrdersTable(model: model, selection: .constant([]), completedOrder: .constant(nil), searchText: .constant(String())).background(Color.white)"), size: screenSize)
            capturePNG("diag-mods", source: probeMergeBase + probeApp(
                "OrdersTable(model: model, selection: .constant([]), completedOrder: .constant(nil), searchText: .constant(String())).tableStyle(.inset).searchable(text: .constant(String()))"), size: screenSize)
            capturePNG("diag-zstack", source: probeMergeBase + probeApp(
                "ZStack { OrdersTable(model: model, selection: .constant([]), completedOrder: .constant(nil), searchText: .constant(String())).tableStyle(.inset) }"), size: screenSize)
            capturePNG("diag-navtitle", source: probeMergeBase + probeApp(
                "OrdersTable(model: model, selection: .constant([]), completedOrder: .constant(nil), searchText: .constant(String())).navigationTitle(String())"), size: screenSize)
            capturePNG("diag-navdest", source: probeMergeBase + probeApp(
                "OrdersTable(model: model, selection: .constant([]), completedOrder: .constant(nil), searchText: .constant(String())).navigationDestination(for: Int.self) { _ in EmptyView() }"), size: screenSize)
            let diagIfDecl = """

            struct __DiagIf: View {
                #if os(iOS)
                @Environment(\\.horizontalSizeClass) private var sizeClass
                #endif
                var displayAsList: Bool {
                    #if os(iOS)
                    return sizeClass == .compact
                    #else
                    return false
                    #endif
                }
                var body: some View {
                    ZStack {
                        if displayAsList {
                            Text(verbatim: String(describing: 1))
                        } else {
                            Rectangle().fill(Color.red).frame(width: 600, height: 400)
                        }
                    }
                }
            }
            """
            capturePNG("diag-if", source: probeMergeBase + diagIfDecl + probeApp(
                "__DiagIf()"), size: screenSize)
            capturePNG("diag-ordersview", source: probeMergeBase + probeApp(
                "OrdersView(model: model)"), size: screenSize)
            capturePNG("diag-geo", source: probeMergeBase + probeApp(
                "GeometryReader { p in ScrollView { DonutGalleryGrid(donuts: model.donuts, width: p.size.width) } }.background(Color.white)"), size: screenSize)
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
