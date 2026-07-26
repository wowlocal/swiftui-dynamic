import SwiftInterpreter
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
    }
}
