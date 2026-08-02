import Testing
import SwiftInterpreter
import SwiftUIBridge

/// Gaps that only became reachable once the interpreter started RUNNING more
/// of an app: firing `.onTapGesture` actions and rendering a path-driven
/// NavigationStack's pushed destination each carried the corpus into code it
/// had never evaluated. Each case below is distilled from the project that
/// surfaced it, and each was RED before its fix.
@Suite struct NewlyReachedCodeTests {
    /// DropDown_Updated's row tap: the view declares BOTH `var expandView:
    /// Bool` and `func expandView(_:)`, reads the property bare and calls the
    /// function with an argument. Native-verified with real swiftc
    /// (`-parse-as-library`) on the same pair — it prints
    /// `called-func-alpha prop-now-true`.
    @Test func aStoredPropertyDoesNotShadowItsSameNamedMethod() throws {
        let source = """
        struct Box {
            var expandView: Bool = false
            var log: String = ""

            func expandView(_ title: String) -> String { "called-func-" + title }

            mutating func run() {
                if expandView {
                    log += "prop-true "
                } else {
                    log += expandView("alpha") + " "
                }
                expandView = true
                log += expandView ? "prop-now-true" : "prop-still-false"
            }
        }
        var box = Box()
        box.run()
        let result = box.log
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("result")?.stringified
                    == "called-func-alpha prop-now-true",
                Comment(rawValue:
                    "a scalar property cannot satisfy a call, so it cannot "
                        + "hide the method; got "
                        + "\(String(describing: interpreter.globals.lookup("result")))"))
    }

    /// eul's status-bar views: `componentConfigStore[.CPU]` where the store
    /// is an `@EnvironmentObject` and declares its own `subscript(_:)`.
    /// Reading a member through the projection already saw the model; a
    /// subscript is a member with an argument list.
    @Test func aSubscriptReachesThroughAnObservedModelProjection() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(source: """
        final class ConfigStore: ObservableObject {
            @Published var values: [String: String] = ["cpu": "CPU-config"]

            subscript(_ key: String) -> String {
                values[key] ?? "missing"
            }
        }

        struct Row: View {
            @EnvironmentObject var store: ConfigStore
            var body: some View { Text(store["cpu"]) }
        }

        struct ContentView: View {
            @StateObject private var store = ConfigStore()
            var body: some View { Row().environmentObject(store) }
        }
        """)
        #expect(strings.contains("CPU-config"),
                Comment(rawValue: "\(strings)"))
    }

    /// winston's `UIColor(hex:)`: `UInt64(hexString, radix: 16) != nil`. The
    /// unsigned carrier claimed the comparison and then rejected `nil` as an
    /// operand, so an ordinary optional test could not run.
    @Test func anUnsignedCarrierStillComparesAgainstNil() throws {
        let source = """
        let parsed = UInt64("ff", radix: 16)
        let present = parsed != nil
        let absent = UInt64("zz", radix: 16) == nil
        let value = parsed != nil ? Int(parsed!) : 0
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("present")?.stringified == "true")
        #expect(interpreter.globals.lookup("absent")?.stringified == "true")
        #expect(interpreter.globals.lookup("value")?.intValue == 255)
    }

    /// The same initializer, one layer down: `radix:` was accepted and then
    /// ignored, so every hex string in the corpus parsed as base 10 — nil for
    /// the Int family, a silent zero for UInt64. Both spellings of "not a
    /// number in this base" must still be nil.
    @Test func theFailableStringInitializerHonorsItsRadix() throws {
        let source = """
        let hex = Int("ff", radix: 16) ?? -1
        let binary = Int("1011", radix: 2) ?? -1
        let octal = Int32("17", radix: 8) ?? -1
        let plain = Int("42") ?? -1
        let notHex = Int("zz", radix: 16) == nil
        let notDecimal = Int("nope") == nil
        let wideHex = UInt64("ff", radix: 16).map { Int($0) } ?? -1
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("hex")?.intValue == 255)
        #expect(interpreter.globals.lookup("binary")?.intValue == 11)
        #expect(interpreter.globals.lookup("octal")?.intValue == 15)
        #expect(interpreter.globals.lookup("plain")?.intValue == 42)
        #expect(interpreter.globals.lookup("notHex")?.stringified == "true")
        #expect(interpreter.globals.lookup("notDecimal")?.stringified == "true")
        #expect(interpreter.globals.lookup("wideHex")?.intValue == 255)
    }
}
