import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// The interpretsWithCompilationConditions knob (the interpretsAsPlatform
// idea for #if DEBUG-family gates): release semantics exclude DEBUG-only
// members. The corpus driver keeps DEBUG active (matching `swift build`
// twins; an experiment flipping it traded oss:Mythic for two release-only
// regressions, 678->677 — see LOOP.md 2026-07-18). The MACHINERY stays
// pinned here.
@Suite struct ReleaseDriverSemanticsTests {
    @MainActor
    @Test func debugOnlyActionsAreExcludedFromDriving() throws {
        let previous = Interpreter.interpretsWithCompilationConditions
        Interpreter.interpretsWithCompilationConditions = []
        defer { Interpreter.interpretsWithCompilationConditions = previous }
        let source = """
        struct Stepper: View {
            @State private var stage = 0
            var body: some View {
                VStack {
                    Text(String("stage:") + String(stage))
                    #if DEBUG
                    Button(String("Back (DEBUG)")) {
                        precondition(stage > 0, "trap: stepped back from 0")
                        stage -= 1
                    }
                    #endif
                    Button(String("Next")) { stage += 1 }
                }
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup { Stepper() }
            }
        }
        """
        // The verifier drives EVERY recorded action; with DEBUG active the
        // back button traps. Release semantics exclude it.
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.actionsInvoked == 1)
    }
}
