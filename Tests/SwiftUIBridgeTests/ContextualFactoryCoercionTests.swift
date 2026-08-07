import Foundation
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// A leading dot that carries ARGUMENTS resolves against a contextual SDK type
/// exactly as a bare one does. `.number` is declared
/// `extension FormatStyle where Self == … { static var number: Self }` and has
/// worked for as long as the contextual coercions have existed; `.units(…)`,
/// `.linearGradient(…)` and `.relative(…)` are declared in the SAME kind of
/// extension and differ only in being a `static func`. Nothing collected them,
/// so every one of them was unconstructible.
///
/// Each expectation below is the HOST's own value for the same spelling, so a
/// fix cannot satisfy them by manufacturing a plausible-looking result.
@Suite struct ContextualFactoryCoercionTests {
    /// Named rather than repeated, so the marker under test is built the way
    /// the evaluator builds one: `GeometryBridge` mints a leading-dot call as
    /// an `ImplicitMemberCall` carrying its `CallArguments`.
    private func marker(
        _ name: String, _ arguments: [(String?, RuntimeValue)]
    ) -> RuntimeValue {
        .native(ImplicitMemberCall(
            name: name,
            arguments: CallArguments(arguments: arguments.map {
                CallArguments.Argument(label: $0.0, value: $0.1)
            })))
    }

    /// The IceCubes shape, at the coercion boundary rather than end to end:
    /// `ServerDate.relativeFormatted` spells exactly this style.
    @MainActor
    @Test func unitsFactoryBuildsTheDeclaredFormatStyle() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let coerced = try GeneratedSDKEnumCoercions.coerce(
            "Duration.UnitsFormatStyle",
            marker("units", [
                ("width", .implicitMember("narrow")),
                ("maximumUnitCount", .native(1)),
            ]),
            context: interpreter)
        let style = try #require(coerced as? Duration.UnitsFormatStyle)
        // Native baseline: the same declaration, compiled.
        #expect(Duration.seconds(100).formatted(style)
            == Duration.seconds(100).formatted(
                .units(width: .narrow, maximumUnitCount: 1)))
        #expect(Duration.seconds(3700).formatted(style)
            == Duration.seconds(3700).formatted(
                .units(width: .narrow, maximumUnitCount: 1)))
    }

    /// The declaration gives six parameters and defaults five of them, so a
    /// caller's spelling is almost never the declared arity. The omitted ones
    /// must take the interface's OWN defaults, not zero values.
    @MainActor
    @Test func omittedArgumentsTakeTheirDeclaredDefaults() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let coerced = try GeneratedSDKEnumCoercions.coerce(
            "Duration.UnitsFormatStyle",
            marker("units", [("width", .implicitMember("wide"))]),
            context: interpreter)
        let style = try #require(coerced as? Duration.UnitsFormatStyle)
        #expect(Duration.seconds(3700).formatted(style)
            == Duration.seconds(3700).formatted(.units(width: .wide)))
        // A different width is a genuinely different glyph run, so the
        // assertion above cannot pass by ignoring the argument entirely.
        #expect(Duration.seconds(3700).formatted(.units(width: .wide))
            != Duration.seconds(3700).formatted(.units(width: .narrow)))
    }

    /// A second, unrelated family through the same mechanism — the point of
    /// the change is that it is not about durations. `.linearGradient` is
    /// declared `extension ShapeStyle where Self == LinearGradient`.
    @MainActor
    @Test func gradientFactoryBuildsItsConcreteShapeStyle() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let coerced = try GeneratedSDKEnumCoercions.coerce(
            "LinearGradient",
            marker("linearGradient", [
                ("colors", .array([
                    .native(Color.red), .native(Color.blue),
                ])),
                ("startPoint", .implicitMember("top")),
                ("endPoint", .implicitMember("bottom")),
            ]),
            context: interpreter)
        let gradient = try #require(coerced as? LinearGradient)
        // LinearGradient is not Equatable, so compare the structural
        // description against the same declaration compiled natively; it
        // carries the stops and both unit points.
        #expect(String(describing: gradient) == String(describing:
            LinearGradient(
                colors: [.red, .blue],
                startPoint: .top, endPoint: .bottom)))
        // The arguments genuinely reach the value: a different endpoint reads
        // differently, so the assertion above is not vacuous.
        #expect(String(describing: gradient) != String(describing:
            LinearGradient(
                colors: [.red, .blue],
                startPoint: .top, endPoint: .trailing)))
    }

    /// Counter-direction: collecting factories must not cost the payload-free
    /// values on the same type. `Date.RelativeFormatStyle` gains `.relative(…)`
    /// and its nested `UnitsStyle` keeps `.wide`.
    @MainActor
    @Test func payloadFreeContextualValuesStillResolve() throws {
        let coerced = try GeneratedSDKEnumCoercions.coerce(
            "Date.RelativeFormatStyle.UnitsStyle", .implicitMember("wide"))
        #expect(coerced as? Date.RelativeFormatStyle.UnitsStyle == .wide)
    }

    /// Counter-direction: a name the interface does not declare is an error,
    /// not a silent nil. A factory arm that swallowed unknown spellings would
    /// turn a typo into a blank render — the very symptom being fixed.
    @MainActor
    @Test func undeclaredFactoryNameIsRejected() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        #expect(throws: (any Error).self) {
            try GeneratedSDKEnumCoercions.coerce(
                "Duration.UnitsFormatStyle",
                marker("nosuchfactory", [("width", .implicitMember("narrow"))]),
                context: interpreter)
        }
    }
}
