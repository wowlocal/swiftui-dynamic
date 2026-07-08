import AppKit
import SwiftUI
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// Breadth probes for the GENERATED gateway table: every modifier here was
/// never hand-written — it exists only because BridgeGen emitted it from the
/// SDK's swiftinterface and the ArgumentMatcher dispatched it.
@Suite struct GeneratedModifierTests {
    @Test func generatedTableIsSubstantial() {
        #expect(GeneratedModifiers.table.count >= 100)
        let variants = GeneratedModifiers.table.values.map(\.count).reduce(0, +)
        #expect(variants >= 180)
    }

    @Test func generatedModifiersDispatchThroughRealRendering() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("typography")
                        .kerning(1.5)
                        .tracking(0.5)
                        .baselineOffset(2)
                        .lineSpacing(4)
                        .allowsHitTesting(true)
                        .accessibilityLabel("probe label")
                    Text("effects")
                        .hueRotation(.degrees(45))
                        .contrast(1.2)
                        .flipsForRightToLeftLayoutDirection(false)
                        .drawingGroup()
                }
            }
        }
        """
        RenderDiagnostics.reset()
        switch InterpreterHost().render(source: source) {
        case .failure(let error):
            Issue.record("render failed: \(error)")
        case .success(let view):
            let hosting = NSHostingView(rootView: view.frame(width: 300, height: 300))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            for (viewName, error) in RenderDiagnostics.errors {
                Issue.record("\(viewName): \(error)")
            }
        }
    }

    @Test func suffixDefaultVariantsMatchBothCallShapes() throws {
        // autocorrectionDisabled() and autocorrectionDisabled(false) are the
        // zero-arg and full variants of one defaulted-parameter overload.
        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(source: #"Text("a").autocorrectionDisabled()"#)
        _ = try interpreter.run(source: #"Text("b").autocorrectionDisabled(false)"#)
    }

    @Test func mismatchedArgumentsAreLocatedErrors() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        do {
            _ = try interpreter.run(source: #"Text("x").kerning("nope")"#)
            Issue.record("expected a dispatch error")
        } catch let error as RuntimeError {
            #expect(error.message.contains("no matching overload"))
            #expect(error.line == 1)
        }
    }

    @Test func generatedConstructorsAreSubstantial() {
        #expect(GeneratedConstructors.table.count >= 12)
    }

    @Test func generatedConstructorsDispatchThroughRealRendering() throws {
        // None of these View inits were ever hand-written.
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack {
                    ContentUnavailableView("No results", systemImage: "magnifyingglass")
                    RenameButton()
                    EmptyView()
                    AngularGradient(gradient: Gradient(colors: [.red, .blue]), center: .center)
                        .frame(width: 40, height: 40)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        switch InterpreterHost().render(source: source) {
        case .failure(let error):
            Issue.record("render failed: \(error)")
        case .success(let view):
            let hosting = NSHostingView(rootView: view.frame(width: 300, height: 400))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            for (viewName, error) in RenderDiagnostics.errors {
                Issue.record("\(viewName): \(error)")
            }
        }
    }

    @Test func hostTypeStaticMembersActAsImplicitMembers() throws {
        // Color.black ≡ .black — including chains through .opacity.
        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(source: #"Text("x").foregroundStyle(Color.red)"#)
        _ = try interpreter.run(source: #"Text("x").background(Color.black.opacity(0.4))"#)
        _ = try interpreter.run(source: #"Text("x").font(Font.headline)"#)
    }

    @Test func handWrittenGatewaysStillWin() throws {
        // padding is in both tables; the hand-written one accepts
        // (.horizontal, 8) which has no generated equivalent shape.
        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(source: #"Text("x").padding(.horizontal, 8)"#)
    }
}
