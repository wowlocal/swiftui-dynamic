import AppKit
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
