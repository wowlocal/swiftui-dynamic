import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// M3 doctrine completion: @Query views RE-RENDER when the live model store
// mutates. refreshQueries fills the boxes per body evaluation; these pin
// the WRITE-driven re-render trigger (store changeSignal -> query view's
// store -> self-healing send) by direct causality: the store is driven
// from the test through the hosted render's interpreter, and the querying
// view's body must re-evaluate within a runloop turn.
@Suite struct QueryRefreshOnWriteTests {
    @MainActor
    @Test func storeWriteFiresChangeSignal() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let store = LiveModelStore.for(interpreter)
        var fired = 0
        store.changeSignal.subscribe(ObjectIdentifier(interpreter)) { fired += 1 }
        store.insert(.string("row"))
        #expect(fired == 1)
    }

    @MainActor
    @Test func storeInsertReRendersQueryingView() throws {
        let source = """
        struct Note {
            var title = ""
        }

        struct NotesView: View {
            @Query private var notes: [Note]
            var body: some View {
                Text("visible \\(notes.count)")
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup { NotesView().background(Color.white) }
            }
        }
        """
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered,
              let interpreter = InterpreterHost.lastInterpreter else {
            Issue.record("render failed: \(rendered)")
            return
        }
        let size = NSSize(width: 220, height: 80)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = hosting
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        // Idle baseline: no store writes -> body evaluations settle flat.
        let store = LiveModelStore.for(interpreter)
        let settled = InterpretedView.bodyEvaluationCount
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let idle = InterpretedView.bodyEvaluationCount
        #expect(idle == settled, "idle pumps must not re-evaluate bodies")

        // The write: a direct store insert (what modelContext.insert does)
        // must re-render the querying view within a turn.
        store.insert(.string("row"))
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let after = InterpretedView.bodyEvaluationCount
        print("PROBE query-rerender settled=\(settled) idle=\(idle) after=\(after)",
              "diags:", RenderDiagnostics.errors.count)
        #expect(after > idle, "the store write did not re-render the querying view")
        #expect(RenderDiagnostics.errors.isEmpty)
    }
}
