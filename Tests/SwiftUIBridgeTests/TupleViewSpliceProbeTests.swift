import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// TupleView sibling semantics: a custom View whose body (or @ViewBuilder
// property) produces MULTIPLE views contributes them as SIBLINGS of the
// enclosing container — native SwiftUI expands the variadic tree through
// custom view bodies. `makeGroup`'s historical VStack wrapper collapsed
// them into one vertical child instead (an HStack laid the pair out
// vertically). These pins compare against the compiled-native twin of the
// same structure, rendered through an identical window-wrapped harness.
@Suite struct TupleViewSpliceProbe {
    struct NativePair: View {
        var body: some View {
            Text("Alpha").font(.title2)
            Text("Beta").font(.title2)
        }
    }

    struct NativeBodyRow: View {
        var body: some View {
            HStack(spacing: 24) {
                NativePair()
                Text("Gamma").font(.title2)
            }
            .padding(30)
        }
    }

    struct NativePropertyRow: View {
        @ViewBuilder var pair: some View {
            Text("Alpha").font(.title2)
            Text("Beta").font(.title2)
        }
        var body: some View {
            HStack(spacing: 24) {
                pair
                Text("Gamma").font(.title2)
            }
            .padding(30)
        }
    }

    @MainActor
    @Test func multiStatementBodySplicesIntoContainer() throws {
        let source = """
        struct Pair: View {
            var body: some View {
                Text(String("Alpha")).font(.title2)
                Text(String("Beta")).font(.title2)
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    HStack(spacing: 24) {
                        Pair()
                        Text(String("Gamma")).font(.title2)
                    }
                    .padding(30)
                }
            }
        }
        """
        try Self.compare(source: source, native: AnyView(NativeBodyRow()), label: "body-splice")
    }

    @MainActor
    @Test func viewBuilderComputedPropertySplices() throws {
        let source = """
        struct Row: View {
            @ViewBuilder var pair: some View {
                Text(String("Alpha")).font(.title2)
                Text(String("Beta")).font(.title2)
            }
            var body: some View {
                HStack(spacing: 24) {
                    pair
                    Text(String("Gamma")).font(.title2)
                }
                .padding(30)
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup { Row() }
            }
        }
        """
        try Self.compare(source: source, native: AnyView(NativePropertyRow()), label: "property-splice")
    }

    @MainActor
    static func compare(source: String, native: AnyView, label: String) throws {
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed: \(rendered)")
            return
        }
        let size = NSSize(width: 360, height: 140)
        let interp = ObservableBindingProbe.bitmap(view, size: size)
        let expected = ObservableBindingProbe.bitmap(native, size: size)
        var differing = 0
        var ink = 0
        for x in 0..<Int(size.width) { for y in 0..<Int(size.height) {
            if expected.colorAt(x: x, y: y).map({ $0.brightnessComponent < 0.9 }) == true { ink += 1 }
            if interp.colorAt(x: x, y: y) != expected.colorAt(x: x, y: y) { differing += 1 }
        } }
        print("PROBE \(label) differing:", differing, "native ink:", ink,
              "diags:", RenderDiagnostics.errors.count)
        for e in RenderDiagnostics.errors.prefix(3) {
            print("PROBE-DIAG \(e.view): \(e.error.message.prefix(100))")
        }
        #expect(ink > 100, "native expectation rendered blank — harness broken")
        #expect(differing == 0, "\(label): interpreted diverges from native by \(differing) px")
    }
}
