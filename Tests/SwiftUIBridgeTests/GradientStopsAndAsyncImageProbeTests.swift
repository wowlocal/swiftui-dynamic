import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// The city-panels root cause pair (live R4 sweep finding): CityView's
// LinearGradient(stops:startPoint:endPoint:) had no bridge arm and
// AsyncImage(url:content:placeholder:) had no builder-closure gateway —
// both city rows failed hard. Stops coerce through Coerce.gradientStops
// (.init(color:location:) markers included) and AsyncImage evaluates its
// interpreted closures at phase time.
@Suite struct GradientStopsAndAsyncImageProbeTests {
    @MainActor
    @Test func stopsGradientMatchesNative() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Rectangle()
                        .fill(LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.15), location: 0.1),
                                .init(color: .black, location: 0.6),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom))
                        .background(Color.white)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 120, height: 160)
        let interp = Self.bitmap(view, size: size)
        let native = Self.bitmap(AnyView(
            Rectangle()
                .fill(LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.15), location: 0.1),
                        .init(color: .black, location: 0.6),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom))
                .background(Color.white)
        ), size: size)
        var mismatched = 0
        for x in 0..<120 {
            for y in 0..<160 {
                let a = interp.colorAt(x: x, y: y)
                let b = native.colorAt(x: x, y: y)
                if let a, let b, abs(a.redComponent - b.redComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
        print("PROBE gradient-stops mismatched:", mismatched)
        #expect(mismatched == 0)
    }

    @MainActor
    @Test func asyncImagePlaceholderMatchesNative() throws {
        // A never-loading file URL keeps AsyncImage on its placeholder on
        // both sides — deterministic without network.
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    AsyncImage(url: URL(string: String("file:///nonexistent-probe.png"))) { image in
                        image
                    } placeholder: {
                        Rectangle().fill(Color.orange).frame(width: 60, height: 40)
                    }
                    .background(Color.white)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 120, height: 80)
        let interp = Self.bitmap(view, size: size)
        let native = Self.bitmap(AnyView(
            AsyncImage(url: URL(string: "file:///nonexistent-probe.png")) { image in
                image
            } placeholder: {
                Rectangle().fill(Color.orange).frame(width: 60, height: 40)
            }
            .background(Color.white)
        ), size: size)
        var mismatched = 0
        for x in 0..<120 {
            for y in 0..<80 {
                let a = interp.colorAt(x: x, y: y)
                let b = native.colorAt(x: x, y: y)
                if let a, let b,
                   abs(a.redComponent - b.redComponent) > 0.02
                    || abs(a.greenComponent - b.greenComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
        print("PROBE async-image-placeholder mismatched:", mismatched)
        #expect(mismatched == 0)
    }

    @MainActor
    static func bitmap(_ view: AnyView, size: NSSize) -> NSBitmapImageRep {
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
