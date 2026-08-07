import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// A contextual SDK type's surface is spelled in TWO declaration positions —
/// static storage and static FUNCS — and the interface sweep read only the
/// first. `Duration` declares `zero` as a `static let` and `seconds(_:)` as a
/// `static func` in the very same `extension Swift.Duration`, so `Duration.zero`
/// was constructible while `Duration.seconds(100)` was not.
///
/// IceCubes surfaced it at `Models/Alias/ServerDate.swift:18`, whose
/// `relativeFormatted` is
/// `Duration.seconds(-date.timeIntervalSinceNow).formatted(.units(width:
/// .narrow, maximumUnitCount: 1))`. With no way to BUILD the receiver, the
/// value stayed an unresolved leading-dot marker, `.formatted(…)` absorbed into
/// a chain, and every relative timestamp on the display-settings screen
/// rendered blank where the compiler prints "2m".
///
/// Every expectation here is the natively-compiled answer, captured by running
/// the same spelling through `xcrun swiftc -O`, never hand-written.
@Suite struct NominalStaticFactoryTests {
    /// The generator collects a same-type static FUNC, not just static storage.
    @Test func generatedCoercionCarriesTheCallShapedStatics() throws {
        let seconds = try GeneratedSDKEnumCoercions.coerce(
            "Duration",
            .native(ImplicitMemberCall(
                name: "seconds",
                arguments: CallArguments(arguments: [
                    CallArguments.Argument(label: nil, value: .native(100.0)),
                ]))),
            context: Interpreter(registry: ViewRegistry()))
        #expect(seconds as? Duration == Duration.seconds(100))
    }

    /// The storage half still answers, so widening the sweep did not trade one
    /// declaration position for the other.
    @Test func theStorageHalfStillAnswers() throws {
        let zero = try GeneratedSDKEnumCoercions.coerce(
            "Duration", .implicitMember("zero"),
            context: Interpreter(registry: ViewRegistry()))
        #expect(zero as? Duration == Duration.zero)
    }

    /// A static returning something OTHER than the enclosing type is not a way
    /// to write a value of it. Without this the sweep could admit any static
    /// and the assertions above would pass for the wrong reason.
    @Test func aStaticThatDoesNotReturnTheTypeIsNotAFactory() {
        #expect(throws: (any Error).self) {
            try GeneratedSDKEnumCoercions.coerce(
                "Duration",
                .native(ImplicitMemberCall(
                    name: "random",
                    arguments: CallArguments(arguments: [
                        CallArguments.Argument(label: nil, value: .native(1.0)),
                    ]))),
                context: Interpreter(registry: ViewRegistry()))
        }
    }

    /// COUNTER-DIRECTION on the clock readers. A named-type duration now
    /// arrives as a real `Duration` where it used to arrive as a marker, and
    /// the two places that destructure durations must read both spellings the
    /// same. `.milliseconds(1500)` is 1.5 seconds either way.
    @MainActor
    @Test func namedAndLeadingDotDurationsAgreeInArithmetic() async throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("named \\(Duration.seconds(3) + 0.0)")
                    Text("dotted \\(0.0 + Duration.milliseconds(1500))")
                }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains { $0.contains("named 3.0") })
        #expect(strings.contains { $0.contains("dotted 1.5") })
    }

    /// COUNTER-DIRECTION on the sleep path: `Task.sleep(for:)` accepts the
    /// named-type spelling as well as the leading dot it already took. The
    /// suspension is what the assertion observes — the text only renders after
    /// the sleep resumes.
    @MainActor
    @Test func taskSleepAcceptsANamedDuration() async throws {
        let source = """
        struct ContentView: View {
            @State private var phase = "waiting"

            var body: some View {
                Text(phase)
                    .task {
                        try? await Task.sleep(for: Duration.milliseconds(1))
                        phase = "resumed"
                    }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("resumed"))
    }
}
