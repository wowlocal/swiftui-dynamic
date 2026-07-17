import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// FoodTruck socialfeed pills: `var title: LocalizedStringKey {
/// .init(name) }` — a computed property returning an init marker. The
/// laziness contract keeps markers unresolved, so they now carry the
/// property's declared type as their hint, and the REAL Text boundary
/// resolves hinted markers (LocalizedStringKey's key IS its literal text
/// in the merged model — the String(localized:) doctrine).
@Suite struct ComputedMarkerHintTests {
    @MainActor
    @Test func hintedInitMarkerResolvesAtTextBoundary() throws {
        let source = """
        struct Model {
            var name: String
            var title: LocalizedStringKey {
                switch name.isEmpty {
                case true:
                    return "Empty"
                case false:
                    return .init(name)
                }
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Text(Model(name: String("Cupertino")).title)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success = rendered else {
            Issue.record("render failed")
            return
        }
        // The REAL registry resolves the hint; assert through the marker
        // shape: evaluating the property yields a TYPED marker.
        let probe = Interpreter(registry: ViewRegistry())
        try probe.run(source: """
        struct Model2 {
            var name: String
            var title: LocalizedStringKey {
                return .init(name)
            }
        }
        let value = Model2(name: String("Cupertino")).title
        """)
        guard case .host(let any)? = probe.globals.lookup("value"),
              let call = any as? ImplicitMemberCall else {
            Issue.record("expected a typed init marker")
            return
        }
        #expect(call.typeHint == "LocalizedStringKey")
    }

    @MainActor
    @Test func localizedStringKeyConstructorYieldsItsText() throws {
        let source = """
        let key = LocalizedStringKey(String("Powdered Chocolate"))
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("key")?.stringValue == "Powdered Chocolate")
    }
}
