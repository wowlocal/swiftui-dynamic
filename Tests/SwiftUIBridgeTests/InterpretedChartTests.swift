import AppKit
import Charts
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// FoodTruck truck/forecast class: Swift Charts executes through the
/// interpreter — the Chart/ChartContent result builders and `.value`
/// plottables are the documented magic-tier gateway; marks are REAL
/// Charts marks (AnyChartContent), so layout, scales, and axes are the
/// framework's own.
@Suite struct InterpretedChartTests {
    @MainActor
    @Test func chartBuilderMethodRendersRealAreaChart() throws {
        let source = """
        struct P2: View {
            var body: some View {
                Chart {
                    marks(seriesKey: String("S"), value: 0)
                }
            }
            @ChartContentBuilder
            func marks(seriesKey: String, value: Double) -> some ChartContent {
                AreaMark(x: .value(String("X"), 1.0), y: .value(String("Y"), 5.0))
                AreaMark(x: .value(String("X"), 2.0), y: .value(String("Y"), 9.0))
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    P2()
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 300, height: 200)
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
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        // The area fills the right side of the plot (x∈[1,2] ramps y 5→9);
        // a blank absorb leaves the whole canvas white.
        var painted = 0
        for x in stride(from: 180, to: 260, by: 8) {
            for y in stride(from: 100, to: 180, by: 8) {
                if let color = rep.colorAt(x: x, y: y),
                   color.redComponent + color.greenComponent + color.blueComponent < 2.7 {
                    painted += 1
                }
            }
        }
        #expect(painted > 10, "area mark region painted \(painted) samples; expected a filled chart")
    }

    /// IceCubes `TagChartView` class (Explore/Components/TagChartView.swift):
    /// the trending-tag sparkline is built with the DATA-DRIVEN initializer
    /// `Chart(sortedHistory) { data in AreaMark(…) }`, whose builder Charts
    /// calls once per element. The bridge only ever called the builder with no
    /// arguments, so a one-parameter builder failed with "missing argument for
    /// parameter 'data'" and every sparkline absorbed to blank — 10 of them on
    /// the `tags-list` R2 screen. Distilled to a 2-field point so the repro
    /// carries no Models/Explore import.
    @MainActor
    @Test func dataDrivenChartCallsBuilderPerElement() throws {
        let source = """
        struct Point: Identifiable {
            let id: Int
            let value: Double
        }

        struct P2: View {
            let points: [Point] = [
                Point(id: 0, value: 1.0),
                Point(id: 1, value: 5.0),
                Point(id: 2, value: 9.0),
            ]

            var body: some View {
                Chart(points) { point in
                    AreaMark(
                        x: .value(String("i"), Double(point.id)),
                        y: .value(String("v"), point.value))
                }
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    P2()
                }
            }
        }
        """
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 300, height: 200)
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
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        // The ramp fills the lower-right of the plot; a builder that never ran
        // leaves the whole canvas white.
        var painted = 0
        for x in stride(from: 180, to: 260, by: 8) {
            for y in stride(from: 100, to: 180, by: 8) {
                if let color = rep.colorAt(x: x, y: y),
                   color.redComponent + color.greenComponent
                       + color.blueComponent < 2.7 {
                    painted += 1
                }
            }
        }
        #expect(
            painted > 10,
            "data-driven Chart painted \(painted) samples; expected a filled chart")
    }

    @MainActor
    @Test func linearGradientFactoryCoercesToRealStyle() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Rectangle()
                        .foregroundStyle(.linearGradient(colors: [.teal, .yellow], startPoint: .bottom, endPoint: .top))
                        .frame(width: 40, height: 40)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success = rendered else {
            Issue.record(".linearGradient(colors:startPoint:endPoint:) failed to render")
            return
        }
    }


    // FoodTruck truck-row pillar class: the `.indigo.shadow(.drop(…))`
    // ShapeStyle CHAIN must coerce through the funnel — before the shadow
    // arm existed, the mark fell to the default accent style with a
    // "mark foregroundStyle shape not bridged" diagnostic.
    @MainActor
    @Test func shadowStyleChainCoercesOnChartMarks() throws {
        RenderDiagnostics.reset()
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Chart {
                        RectangleMark(
                            x: .value(String("X"), 1.0),
                            yStart: .value(String("Y"), 0.0),
                            yEnd: .value(String("Y"), 5.0),
                            width: .fixed(6)
                        )
                        .foregroundStyle(.indigo.shadow(.drop(color: .white.opacity(0.25), radius: 0, x: 1)))
                    }
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success = rendered else {
            Issue.record("shadow-chain chart failed to render")
            return
        }
        let styleDrops = RenderDiagnostics.errors.filter {
            $0.error.message.contains("mark foregroundStyle shape not bridged")
        }
        #expect(styleDrops.isEmpty)
    }

    // Custom axis DSL: DateBins-driven X marks and an interpreted per-value
    // Y label closure (AxisValue.as + formatted) run through REAL AxisMarks.
    @MainActor
    @Test func customAxisBuildersRenderInterpretedLabels() throws {
        let source = """
        struct P2: View {
            var body: some View {
                Chart {
                    marks()
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(minimumStride: 2, desiredCount: 4, roundLowerBound: false)) { value in
                        AxisValueLabel("Y\\(value.as(Double.self)!.formatted())")
                        AxisTick()
                        AxisGridLine()
                    }
                }
            }
            @ChartContentBuilder
            func marks() -> some ChartContent {
                AreaMark(x: .value(String("X"), 1.0), y: .value(String("Y"), 5.0))
                AreaMark(x: .value(String("X"), 2.0), y: .value(String("Y"), 9.0))
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    P2()
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 300, height: 200)
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
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        // The interpreted Y-labels ("Y5", …) paint dark pixels in the
        // trailing label gutter; default axes label differently but the
        // assertion is presence-of-label-ink, tolerant to layout shifts.
        var inked = 0
        for x in stride(from: 265, to: 298, by: 3) {
            for y in stride(from: 10, to: 190, by: 4) {
                if let color = rep.colorAt(x: x, y: y),
                   color.redComponent + color.greenComponent + color.blueComponent < 2.0 {
                    inked += 1
                }
            }
        }
        #expect(inked > 3, "custom Y-axis labels did not paint (inked=\(inked))")
    }
}

extension InterpretedChartTests {
    // The salesHistory live class: `.foregroundStyle(by: .value(...))` /
    // `.symbol(by:)` (categorical series) and `.lineStyle(StrokeStyle)`
    // had no mark-member arms — every mark logged "shape not bridged" and
    // painted the default style. The by: forms route through the shared
    // plottable carrier now; series colors, symbols, and the legend are
    // the framework's own.
    @MainActor
    @Test func seriesColoredMarksMatchNative() throws {
        let source = """
        struct P2: View {
            var body: some View {
                Chart {
                    LineMark(x: .value(String("X"), 1.0), y: .value(String("Y"), 5.0))
                        .foregroundStyle(by: .value(String("City"), String("A")))
                        .symbol(by: .value(String("City"), String("A")))
                        .lineStyle(StrokeStyle(lineWidth: 3))
                    LineMark(x: .value(String("X"), 2.0), y: .value(String("Y"), 9.0))
                        .foregroundStyle(by: .value(String("City"), String("A")))
                        .symbol(by: .value(String("City"), String("A")))
                        .lineStyle(StrokeStyle(lineWidth: 3))
                    LineMark(x: .value(String("X"), 1.0), y: .value(String("Y"), 2.0))
                        .foregroundStyle(by: .value(String("City"), String("B")))
                        .symbol(by: .value(String("City"), String("B")))
                        .lineStyle(StrokeStyle(lineWidth: 3))
                    LineMark(x: .value(String("X"), 2.0), y: .value(String("Y"), 4.0))
                        .foregroundStyle(by: .value(String("City"), String("B")))
                        .symbol(by: .value(String("City"), String("B")))
                        .lineStyle(StrokeStyle(lineWidth: 3))
                }
                .background(Color.white)
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    P2()
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 300, height: 200)
        let interp = Self.chartBitmap(view, size: size)
        let native = Self.chartBitmap(AnyView(
            Chart {
                LineMark(x: .value("X", 1.0), y: .value("Y", 5.0))
                    .foregroundStyle(by: .value("City", "A"))
                    .symbol(by: .value("City", "A"))
                    .lineStyle(StrokeStyle(lineWidth: 3))
                LineMark(x: .value("X", 2.0), y: .value("Y", 9.0))
                    .foregroundStyle(by: .value("City", "A"))
                    .symbol(by: .value("City", "A"))
                    .lineStyle(StrokeStyle(lineWidth: 3))
                LineMark(x: .value("X", 1.0), y: .value("Y", 2.0))
                    .foregroundStyle(by: .value("City", "B"))
                    .symbol(by: .value("City", "B"))
                    .lineStyle(StrokeStyle(lineWidth: 3))
                LineMark(x: .value("X", 2.0), y: .value("Y", 4.0))
                    .foregroundStyle(by: .value("City", "B"))
                    .symbol(by: .value("City", "B"))
                    .lineStyle(StrokeStyle(lineWidth: 3))
            }
            .background(Color.white)
        ), size: size)
        var mismatched = 0
        for x in 0..<300 {
            for y in 0..<200 {
                let a = interp.colorAt(x: x, y: y)
                let b = native.colorAt(x: x, y: y)
                if let a, let b,
                   abs(a.redComponent - b.redComponent) > 0.02
                    || abs(a.greenComponent - b.greenComponent) > 0.02
                    || abs(a.blueComponent - b.blueComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
        print("PROBE series-colored-marks mismatched:", mismatched)
        #expect(mismatched == 0)
    }

    @MainActor
    static func chartBitmap(_ view: AnyView, size: NSSize) -> NSBitmapImageRep {
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
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fatalError("no rep")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }
}

extension InterpretedChartTests {
    // The topfive live class: AxisValueLabel(format: IntegerFormatStyle<Int>())
    // reached the bridge as an inert stub (thrown), the content-closure form
    // rendered empty, and the closure content's .frame(idealWidth:) had no
    // gateway arm. The integer look bridges through a fraction-0 floating
    // format (bridged plottables are Double-backed — same label strings),
    // closure labels evaluate their interpreted builders, and frame gains
    // ideal dimensions.
    @MainActor
    @Test func integerAxisAndClosureLabelsMatchNative() throws {
        let source = """
        struct P2: View {
            var body: some View {
                Chart {
                    BarMark(x: .value(String("X"), String("A")), y: .value(String("Y"), 250.0))
                    BarMark(x: .value(String("X"), String("B")), y: .value(String("Y"), 500.0))
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: IntegerFormatStyle<Int>())
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            Text(String("donut"))
                                .frame(idealWidth: 80)
                        }
                    }
                }
                .background(Color.white)
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    P2()
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 300, height: 200)
        let interp = Self.chartBitmap(view, size: size)
        let native = Self.chartBitmap(AnyView(
            Chart {
                BarMark(x: .value("X", "A"), y: .value("Y", 250))
                BarMark(x: .value("X", "B"), y: .value("Y", 500))
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: IntegerFormatStyle<Int>())
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel {
                        Text("donut")
                            .frame(idealWidth: 80)
                    }
                }
            }
            .background(Color.white)
        ), size: size)
        var mismatched = 0
        for x in 0..<300 {
            for y in 0..<200 {
                let a = interp.colorAt(x: x, y: y)
                let b = native.colorAt(x: x, y: y)
                if let a, let b,
                   abs(a.redComponent - b.redComponent) > 0.02
                    || abs(a.blueComponent - b.blueComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
        print("PROBE integer-axis-closure-labels mismatched:", mismatched)
        #expect(mismatched == 0)
    }

    // The saleshistory R2 class: `.chartLegend(position: .top)` (generated
    // tier — Charts joined the BridgeGen modifier sweep) and the bare
    // `AxisValueLabel()` inside a custom AxisMarks builder rendering the
    // AUTOMATIC formatted value (an empty-string title suppressed it).
    @MainActor
    @Test func legendPositionAndBareAxisLabelsMatchNative() throws {
        let source = """
        struct P2: View {
            var body: some View {
                Chart {
                    LineMark(x: .value(String("D"), 1.0), y: .value(String("S"), 100.0))
                        .foregroundStyle(by: .value(String("City"), String("Cupertino")))
                    LineMark(x: .value(String("D"), 2.0), y: .value(String("S"), 180.0))
                        .foregroundStyle(by: .value(String("City"), String("Cupertino")))
                    LineMark(x: .value(String("D"), 1.0), y: .value(String("S"), 60.0))
                        .foregroundStyle(by: .value(String("City"), String("London")))
                    LineMark(x: .value(String("D"), 2.0), y: .value(String("S"), 90.0))
                        .foregroundStyle(by: .value(String("City"), String("London")))
                }
                .chartLegend(position: .top)
                .chartXAxis {
                    AxisMarks { value in
                        if value.index < value.count - 1 {
                            AxisValueLabel()
                        }
                        AxisTick()
                        AxisGridLine()
                    }
                }
                .background(Color.white)
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    P2()
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 300, height: 200)
        let interp = Self.chartBitmap(view, size: size)
        let native = Self.chartBitmap(AnyView(
            Chart {
                LineMark(x: .value("D", 1.0), y: .value("S", 100.0))
                    .foregroundStyle(by: .value("City", "Cupertino"))
                LineMark(x: .value("D", 2.0), y: .value("S", 180.0))
                    .foregroundStyle(by: .value("City", "Cupertino"))
                LineMark(x: .value("D", 1.0), y: .value("S", 60.0))
                    .foregroundStyle(by: .value("City", "London"))
                LineMark(x: .value("D", 2.0), y: .value("S", 90.0))
                    .foregroundStyle(by: .value("City", "London"))
            }
            .chartLegend(position: .top)
            .chartXAxis {
                AxisMarks { value in
                    if value.index < value.count - 1 {
                        AxisValueLabel()
                    }
                    AxisTick()
                    AxisGridLine()
                }
            }
            .background(Color.white)), size: size)
        var mismatched = 0
        for x in 0..<300 {
            for y in 0..<200 {
                let a = interp.colorAt(x: x, y: y)
                let b = native.colorAt(x: x, y: y)
                if let a, let b,
                   abs(a.redComponent - b.redComponent) > 0.02
                    || abs(a.greenComponent - b.greenComponent) > 0.02
                    || abs(a.blueComponent - b.blueComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
        print("PROBE legend-position-bare-axis-labels mismatched:", mismatched)
        #expect(mismatched == 0)
    }

    /// IceCubes `TagChartView` class (Explore/Components/TagChartView.swift):
    /// the trending-tag sparkline hides both axes with `.chartXAxis(.hidden)` /
    /// `.chartYAxis(.hidden)`, so the twin draws a bare ramp while the
    /// interpreted capture drew tick labels and gridlines — the bulk of the
    /// `tags-list` R2 residue.
    ///
    /// The name is the whole failure: `ChartsBridge` registers a handwritten
    /// adapter for `chartXAxis` to serve the `@AxisContentBuilder` overload,
    /// and a handwritten adapter shadows EVERY generated overload of the same
    /// name. The `Visibility` overload is generated
    /// (`GeneratedModifiers` — interface line `chartXAxis(_ visibility:)`),
    /// but the call never reached it: the handwritten body found no closure
    /// and returned the receiver unchanged.
    ///
    /// Both spellings are asserted together, because a fix that reaches the
    /// generated overload by dropping the handwritten one would take the
    /// builder overload down with it.
    @MainActor
    @Test func axisVisibilityReachesGeneratedOverloadBesideBuilderOverload() throws {
        let source = """
        struct P2: View {
            var body: some View {
                Chart {
                    AreaMark(x: .value(String("X"), 1.0), y: .value(String("Y"), 5.0))
                    AreaMark(x: .value(String("X"), 2.0), y: .value(String("Y"), 9.0))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    P2()
                }
            }
        }
        """
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 300, height: 200)
        let hidden = Self.chartBitmap(view, size: size)
        // The expectation is a REAL compiled chart with the same modifiers,
        // never a hand-written pixel count.
        let nativeHidden = Self.chartBitmap(AnyView(
            Chart {
                AreaMark(x: .value("X", 1.0), y: .value("Y", 5.0))
                AreaMark(x: .value("X", 2.0), y: .value("Y", 9.0))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)), size: size)
        // …and a compiled chart WITHOUT them, so "hidden" is proven to be a
        // visible difference rather than a no-op both sides agree on.
        let nativeShown = Self.chartBitmap(AnyView(
            Chart {
                AreaMark(x: .value("X", 1.0), y: .value("Y", 5.0))
                AreaMark(x: .value("X", 2.0), y: .value("Y", 9.0))
            }), size: size)

        func mismatches(
            _ a: NSBitmapImageRep, _ b: NSBitmapImageRep
        ) -> Int {
            var count = 0
            for x in 0..<Int(size.width) {
                for y in 0..<Int(size.height) {
                    guard let lhs = a.colorAt(x: x, y: y),
                          let rhs = b.colorAt(x: x, y: y) else { continue }
                    if abs(lhs.redComponent - rhs.redComponent) > 0.02
                        || abs(lhs.greenComponent - rhs.greenComponent) > 0.02
                        || abs(lhs.blueComponent - rhs.blueComponent) > 0.02 {
                        count += 1
                    }
                }
            }
            return count
        }

        let axisPixels = mismatches(nativeHidden, nativeShown)
        #expect(
            axisPixels > 100,
            "compiled hidden/shown axes differ by \(axisPixels) px; the control is degenerate and the assertion below proves nothing")
        let drift = mismatches(hidden, nativeHidden)
        print("PROBE hidden-axis drift:", drift, "axis px:", axisPixels)
        #expect(
            drift == 0,
            "interpreted `.chartXAxis(.hidden)` differs from the compiled chart by \(drift) px; the axes were drawn anyway")
    }

    /// The builder overload of the SAME name must keep working — it is the
    /// half `ChartsBridge` legitimately owns (`@AxisContentBuilder` builds
    /// `AxisContent`, an associated-type protocol no generated tier carries).
    @MainActor
    @Test func axisBuilderOverloadSurvivesGeneratedFallthrough() throws {
        let source = """
        struct P2: View {
            var body: some View {
                Chart {
                    AreaMark(x: .value(String("X"), 1.0), y: .value(String("Y"), 5.0))
                    AreaMark(x: .value(String("X"), 2.0), y: .value(String("Y"), 9.0))
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisTick()
                        AxisGridLine()
                    }
                }
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    P2()
                }
            }
        }
        """
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 300, height: 200)
        let interp = Self.chartBitmap(view, size: size)
        let native = Self.chartBitmap(AnyView(
            Chart {
                AreaMark(x: .value("X", 1.0), y: .value("Y", 5.0))
                AreaMark(x: .value("X", 2.0), y: .value("Y", 9.0))
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisTick()
                    AxisGridLine()
                }
            }), size: size)
        var mismatched = 0
        for x in 0..<Int(size.width) {
            for y in 0..<Int(size.height) {
                guard let a = interp.colorAt(x: x, y: y),
                      let b = native.colorAt(x: x, y: y) else { continue }
                if abs(a.redComponent - b.redComponent) > 0.02
                    || abs(a.greenComponent - b.greenComponent) > 0.02
                    || abs(a.blueComponent - b.blueComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
        print("PROBE axis-builder drift:", mismatched)
        #expect(mismatched == 0)
    }

    /// The other side of the same fallthrough: a declined call that the
    /// generated tier ALSO cannot serve must keep the behaviour it had, not
    /// start throwing. IceCubes' `AccountMetricsComponents.swift:63` is the
    /// live instance — `.chartYScale(domain: 0...max(value, 1))` carries a
    /// range domain, and `Charts.ScaleDomain` coerces only from `.automatic`,
    /// so no generated overload fits. Routing it out of the handwritten
    /// adapter unconditionally would turn a rendered screen into a runtime
    /// error, which is why the fallthrough is conditioned on a real match.
    @MainActor
    @Test func declinedCallNoTierServesKeepsItsExistingAdapter() throws {
        let source = """
        struct P2: View {
            var body: some View {
                Chart {
                    AreaMark(x: .value(String("X"), 1.0), y: .value(String("Y"), 5.0))
                    AreaMark(x: .value(String("X"), 2.0), y: .value(String("Y"), 9.0))
                }
                .chartYScale(domain: 0...12)
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    P2()
                }
            }
        }
        """
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed — an unserveable domain must absorb, not throw")
            return
        }
        // Absorbing the domain still has to leave a drawn chart behind.
        let size = NSSize(width: 300, height: 200)
        let rep = Self.chartBitmap(view, size: size)
        var painted = 0
        for x in stride(from: 40, to: 290, by: 4) {
            for y in stride(from: 10, to: 190, by: 4) {
                if let color = rep.colorAt(x: x, y: y),
                   color.redComponent + color.greenComponent
                       + color.blueComponent < 2.7 {
                    painted += 1
                }
            }
        }
        #expect(
            painted > 10,
            "chart painted \(painted) samples; an unserveable scale domain took the whole chart with it")
    }
}
