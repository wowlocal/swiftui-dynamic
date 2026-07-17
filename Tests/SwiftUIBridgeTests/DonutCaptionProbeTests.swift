import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// FoodTruck donuts-row class (0.437%): the grid captions sit ~3px higher
/// on the interpreter. These pins ELIMINATE the caption block, the
/// NavigationLink cell structure, and erased-ZStack spacing preferences —
/// each matches native pixel-exactly. The residual divergence lives in
/// the real DonutView's interpreted layout (staked in LOOP.md).
@Suite struct DonutCaptionProbeTests {
    @MainActor
    @Test func donutCellChromeMatchesNative() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 20, alignment: .top)], spacing: 20) {
                    ForEach(0..<1) { _ in
                    NavigationLink(value: 1) {
                        VStack {
                            GeometryReader { proxy in
                                ZStack {
                                    Circle().fill(Color.gray)
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .compositingGroup()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .frame(width: 40, height: 40)
                            VStack {
                                Text(String("The Classic"))
                                HStack(spacing: 4) {
                                    Image(systemName: String("face.smiling"))
                                    Text(String("Savory"))
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.center)
                        }
                    }
                    .buttonStyle(.plain)
                    }
                    }
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 160, height: 130)
        let interp = Self.bitmap(view, size: size)
        let native = Self.bitmap(AnyView(
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 20, alignment: .top)], spacing: 20) {
            ForEach(0..<1) { _ in
            NavigationLink(value: 1) {
                VStack {
                    GeometryReader { _ in
                        ZStack {
                            Circle().fill(Color.gray)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .compositingGroup()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: 40, height: 40)
                    VStack {
                        Text("The Classic")
                        HStack(spacing: 4) {
                            Image(systemName: "face.smiling")
                            Text("Savory")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
            }
            .buttonStyle(.plain)
            }
            }
        ), size: size)
        var mismatched = 0
        for x in 0..<160 {
            for y in 0..<130 {
                let a = interp.colorAt(x: x, y: y)
                let b = native.colorAt(x: x, y: y)
                if let a, let b, abs(a.redComponent - b.redComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
        print("PROBE mismatched:", mismatched)
        #expect(mismatched == 0)
    }

    @MainActor
    private static func bitmap(_ view: AnyView, size: NSSize) -> NSBitmapImageRep {
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
