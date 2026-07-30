import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct BuilderLetProbeTests {
    /// An escaping result-builder closure keeps the lexical type scope where
    /// it was authored. Nested constants must resolve against that owner when
    /// the generic container invokes the closure later.
    @Test func escapingBuilderRetainsNestedLexicalConstants() throws {
        let interpreter = Interpreter(registry: TraceRegistry())
        _ = try interpreter.run(source: """
        struct BuilderContainer<Content: View>: View {
            private let content: (Bool) -> Content

            init(
                @ViewBuilder content: @escaping (Bool) -> Content
            ) {
                self.content = content
            }

            var body: some View {
                content(true)
            }
        }

        struct Card: View {
            enum Metrics {
                static let height: CGFloat = 37
            }

            var body: some View {
                BuilderContainer { loaded in
                    if loaded {
                        Color.red.frame(
                            width: 40, height: Metrics.height)
                    }
                }
            }
        }

        Card()
        """)
        guard case .type(let symbol)? =
                interpreter.globals.lookup("Card")
        else {
            Issue.record("Card type was not collected")
            return
        }
        guard case .instance(let card) = try interpreter.instantiateRoot(
            symbol)
        else {
            Issue.record("Card did not instantiate")
            return
        }

        let cardBody = try TraceRegistry.node(
            interpreter.evaluateBody(of: card))
        let container = try #require(
            cardBody.instance ?? cardBody.children.first?.instance)
        let containerBody = try TraceRegistry.node(
            interpreter.evaluateBody(of: container))
        let frame = try #require(
            (containerBody.children.first ?? containerBody)
                .modifiers.first {
                $0.hasPrefix("frame(")
            })
        #expect(frame.contains("height: 37"))
        #expect(!frame.contains("height: 0"))
    }

    @MainActor
    @Test func letBindingInBuilderAddsNoPhantomChild() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    VStack {
                        Rectangle().fill(Color.gray).frame(width: 40, height: 40)
                        VStack {
                            let title = String("The Classic")
                            Text(title)
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
            VStack {
                Rectangle().fill(Color.gray).frame(width: 40, height: 40)
                VStack {
                    let title = "The Classic"
                    Text(title)
                    HStack(spacing: 4) {
                        Image(systemName: "face.smiling")
                        Text("Savory")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
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
        print("PROBE let-mismatched:", mismatched)
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
