import AppKit
import SwiftInterpreter
import SwiftUI
import Testing
@testable import SwiftUIBridge

@Suite(.serialized)
struct InterpreterHostSessionTests {
    @Test
    func renderSessionRetainsItsOwningInterpreter() throws {
        let first = try InterpreterHost().renderSession(
            source: """
            let sessionMarker = "first"
            struct SessionView: View {
                var body: some View {
                    Text(sessionMarker)
                }
            }
            SessionView()
            """
        ).get()
        let second = try InterpreterHost().renderSession(
            source: """
            let sessionMarker = "second"
            struct SessionView: View {
                var body: some View {
                    Text(sessionMarker)
                }
            }
            SessionView()
            """
        ).get()

        #expect(first.interpreter !== second.interpreter)
        #expect(first.interpreter.globals.lookup("sessionMarker")?.stringValue
            == "first")
        #expect(second.interpreter.globals.lookup("sessionMarker")?.stringValue
            == "second")
        #expect(first.interpreter.runtimeActivity.isQuiescent)
        #expect(second.interpreter.runtimeActivity.isQuiescent)
        #expect(InterpreterHost.lastInterpreter === second.interpreter)

        let firstBaseline = first.renderActivity
        let secondBaseline = second.renderActivity
        Self.display(first.view)
        let firstPresented = first.renderActivity
        #expect(firstPresented.bodyEvaluationCount
            > firstBaseline.bodyEvaluationCount)
        #expect(second.renderActivity == secondBaseline)

        Self.display(second.view)
        #expect(first.renderActivity == firstPresented)
        #expect(second.renderActivity.bodyEvaluationCount
            > secondBaseline.bodyEvaluationCount)
    }

    private static func display(_ view: AnyView) {
        let size = NSSize(width: 80, height: 48)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.contentView = nil
    }
}
