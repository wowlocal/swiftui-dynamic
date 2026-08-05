import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// A framework-owned callback whose declared RESULT is an SDK value, not
/// `Void`.
///
/// BridgeGen already reconstitutes callbacks the SDK calls back into
/// interpreted code, but only over a closed set of result shapes: `() -> Void`,
/// `() async -> Void`, and a one-concrete-input callback whose result is
/// `Void` or `CGFloat`. Any other declared result left the whole overload
/// ungeneratable, so the modifier had no entry at all — and a modifier chain
/// absorbs from its FIRST unbridged member, taking every later modifier with
/// it.
///
/// Surfaced by IceCubes' `MediaUIView.swift:29`, where
/// `.onKeyPress(.leftArrow, action: { ...; return .handled })` is the first
/// unbridged member of the media-browser screen's chain — everything above it
/// (`.focusable()`, `.focused($isFocused)`, `.focusEffectDisabled()`) is
/// bridged, so this single result type gates the screen.
///
/// The class is NOT about key presses. It is that the generator resolved a
/// closure's result through a two-case list instead of through the same
/// coercion vocabulary it already applies to every parameter. The same
/// generalization reaches `() -> SensoryFeedback`, `(T, T) -> Bool`,
/// `(DropSession) -> DropConfiguration` and the rest of the 99 closure-shaped
/// blocked overloads BridgeGen's own `--report-json` counts.
///
/// These cases drive `GeneratedDispatch.serves` — the predicate deciding
/// whether the generated tier fits a call — for the reason
/// `WrapperProjectionCarrierTests` records: when the symptom is a MISSING
/// modifier, a render assertion cannot see it, because an unmatched modifier
/// deliberately leaves its receiver visible and the tree looks identical
/// either way.
@Suite(.serialized)
struct CallbackResultCoercionTests {
    /// Evaluate each argument expression, then ask the generated tier whether
    /// `modifier` fits that argument list.
    @MainActor
    private static func serves(
        _ modifier: String,
        _ arguments: [(String?, String)]
    ) throws -> Bool {
        let interpreter = Interpreter()
        var values: [CallArguments.Argument] = []
        for (label, expression) in arguments {
            let value = try interpreter.run(source: expression)
            values.append(.init(label: label, value: value))
        }
        let overloads = try #require(GeneratedModifiers.table[modifier])
        return GeneratedDispatch.serves(
            overloads: overloads,
            args: CallArguments(arguments: values),
            ctx: interpreter)
    }

    /// The exact shape IceCubes writes: a keyed callback taking nothing and
    /// returning an SDK enum. `() -> R` was not handled at ANY result type —
    /// only `() -> Void` and `() async -> Void` were.
    @MainActor
    @Test func aZeroInputSDKResultCallbackFitsOnKeyPress() throws {
        #expect(try Self.serves("onKeyPress", [
            (nil, ".leftArrow"),
            ("action", "{ .handled }"),
        ]))
    }

    /// The one-input shape over the same result type. `syncVoidClosure` /
    /// `syncCGFloatClosure` already carried one concrete input; the result was
    /// what excluded it.
    @MainActor
    @Test func aKeyPressInputCallbackFitsOnKeyPress() throws {
        #expect(try Self.serves("onKeyPress", [
            ("phases", ".down"),
            ("action", "{ press in .handled }"),
        ]))
    }

    /// The negative control. Reconstituting a callback result must not make
    /// the parameter a hole that accepts anything: a non-closure argument in
    /// the action position must still fit no overload, or the generalization
    /// would be laundering type errors into silent no-ops.
    @MainActor
    @Test func aBareValueStillFitsNoOnKeyPressOverload() throws {
        #expect(try !Self.serves("onKeyPress", [
            (nil, ".leftArrow"),
            ("action", "true"),
        ]))
    }

    /// The callbacks already generated keep their existing shapes:
    /// `onTapGesture` is the `() -> Void` path and `accessibilityScrollAction`
    /// the one-concrete-input `Void` path, so a regression in either is a
    /// regression in the tag they share.
    ///
    /// Both are named from the emitted table rather than from memory. The
    /// first draft of this control asserted `onAppear(perform:)` and cited
    /// `onGeometryChange`, and NEITHER is generated — `onAppear` is emitted
    /// only in its zero-argument form because `perform:` is declared
    /// `(() -> Void)?`, an optional closure this file does not map, and
    /// `onGeometryChange` has no entry at all. It failed on first run for that
    /// reason and not because anything regressed.
    @MainActor
    @Test func existingCallbackShapesAreUnaffected() throws {
        #expect(try Self.serves("onTapGesture", [("perform", "{ }")]))
        #expect(try Self.serves(
            "accessibilityScrollAction", [(nil, "{ direction in }")]))
    }

    /// The generalization SUBSUMES the special case it replaced rather than
    /// sitting beside it. `alignmentGuide`'s `(ViewDimensions) -> CGFloat` was
    /// the entire reason a `syncCGFloatClosure` tag existed; it is now served
    /// by the same `syncClosure` tag as every other result type. That the
    /// closed list is GONE rather than merely extended is enforced by the
    /// compiler — the tag no longer exists as an enum case — so this pins the
    /// behaviour that migration had to preserve.
    @MainActor
    @Test func theReplacedCGFloatShapeIsServedByTheGeneralPath() throws {
        #expect(try Self.serves("alignmentGuide", [
            (nil, ".leading"),
            ("computeValue", "{ dimensions in 0 }"),
        ]))
    }

    /// End to end: the chain IceCubes writes renders its content and records
    /// no diagnostic, so a bridged modifier was not traded for a broken
    /// render.
    @Test func theSurfacingChainStillRenders() async throws {
        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let strings = try await LiveCheckSupport.renderedStrings(source: """
        struct ContentView: View {
            @FocusState private var isFocused: Bool

            var body: some View {
                VStack {
                    Text("body-text")
                        .focusable()
                        .focused($isFocused)
                        .focusEffectDisabled()
                        .onKeyPress(.leftArrow, action: { .handled })
                }
            }
        }
        """)
        #expect(strings.contains("body-text"),
                Comment(rawValue: "\(strings.filter { !$0.isEmpty })"))
        #expect(RenderDiagnostics.errors.isEmpty,
                Comment(rawValue:
                    "\(RenderDiagnostics.errors.map(\.error.message))"))
    }
}
