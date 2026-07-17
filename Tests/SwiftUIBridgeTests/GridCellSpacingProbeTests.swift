import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct GridCellSpacingProbeTests {
    static let cellSource = """
    VStack {
        GeometryReader { proxy in
            ZStack {
                Circle().fill(Color.gray)
            }
            .aspectRatio(1, contentMode: .fit)
            .compositingGroup()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 80, height: 80)
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
    """

    @MainActor
    @Test func gridCellCaptionGapMatchesNative() throws {
        let source = """
        struct D: Identifiable {
            let id: Int
            let name: String
        }

        @main
        struct P: App {
            var items: [D] {
                [D(id: 1, name: String("The Classic")), D(id: 2, name: String("B")),
                 D(id: 3, name: String("C")), D(id: 4, name: String("D"))]
            }
            var body: some Scene {
                WindowGroup {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20, alignment: .top)], spacing: 20) {
                        ForEach(items) { item in
                            \(Self.cellSource)
                        }
                    }
                    .padding()
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
        let size = NSSize(width: 700, height: 300)
        let interp = Self.bitmap(view, size: size)
        let native = Self.bitmap(AnyView(
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20, alignment: .top)], spacing: 20) {
                ForEach([1, 2, 3, 4], id: \.self) { _ in
                    VStack {
                        GeometryReader { _ in
                            ZStack {
                                Circle().fill(Color.gray)
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .compositingGroup()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(width: 80, height: 80)
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
            }
            .padding()
            .background(Color.white)
        ), size: size)
        var mismatched = 0
        for x in 0..<700 {
            for y in 0..<300 {
                let a = interp.colorAt(x: x, y: y)
                let b = native.colorAt(x: x, y: y)
                if let a, let b, abs(a.redComponent - b.redComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
        print("PROBE grid-cell mismatched:", mismatched)
        #expect(mismatched == 0)
    }

    // The root cause of the donuts-gallery caption drift: GridItem's
    // constructor dropped `alignment:`, so SHORTER cells centered in
    // their row instead of pinning to .top. Height-unequal cells make
    // the alignment observable (equal-height grids masked it).
    @MainActor
    @Test func gridItemAlignmentTopPinsUnequalCells() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 10, alignment: .top)], spacing: 10) {
                        Rectangle().fill(Color.black).frame(width: 40, height: 30)
                        Rectangle().fill(Color.black).frame(width: 40, height: 70)
                        Rectangle().fill(Color.black).frame(width: 40, height: 50)
                    }
                    .padding()
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
        let size = NSSize(width: 260, height: 120)
        let interp = Self.bitmap(view, size: size)
        let native = Self.bitmap(AnyView(
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 10, alignment: .top)], spacing: 10) {
                Rectangle().fill(Color.black).frame(width: 40, height: 30)
                Rectangle().fill(Color.black).frame(width: 40, height: 70)
                Rectangle().fill(Color.black).frame(width: 40, height: 50)
            }
            .padding()
            .background(Color.white)
        ), size: size)
        var mismatched = 0
        for x in 0..<260 {
            for y in 0..<120 {
                let a = interp.colorAt(x: x, y: y)
                let b = native.colorAt(x: x, y: y)
                if let a, let b, abs(a.redComponent - b.redComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
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
