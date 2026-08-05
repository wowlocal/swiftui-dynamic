import SwiftUI
import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// A leading-dot `.init(…)` written at a parameter typed as a generic
/// INSTANTIATION has to find that type's initializers.
///
/// `MediaUIShareLink.swift:15` writes exactly that:
/// `ShareLink(item: transferable, preview: .init(…, image: transferable))`.
/// Once `preview` was typed `SharePreview<InterpretedTransferableValue,
/// Never>`, contextual resolution looked the WHOLE spelling up in the
/// constructor table, which is keyed by nominal — `SharePreview` — so it found
/// nothing, `.init` stayed an unresolved marker, every overload rejected it,
/// and the screen reported `no matching initializer for
/// ShareLink(item:preview:)`. A Swift initializer belongs to the generic type
/// and the arguments choose the instantiation, so the lookup is by nominal.
///
/// WHERE THIS CLASS IS PINNED, stated exactly, because it is NOT pinned here.
/// The R2 media-browser floor carries it: 1136 AE -> 0, ratcheted in the same
/// commit and enforced by the close gate. Three cheaper instruments were tried
/// and every one is blind to it. `renderedStrings` renders an absorbed bag
/// whether or not the initializer resolves. `RenderDiagnostics.errors` stays
/// EMPTY on that path even for a deliberately bogus
/// `ShareLink(bogusArgument:preview:)` control. And a direct
/// `GeneratedDispatch.coerce` test cannot reach the resolution either:
/// `invokeHostConstructor` returns nil on a bare `Interpreter()`, because the
/// constructor table is bootstrapped by the render harness, so such a test
/// fails identically with and without the fix.
///
/// What IS kept below is the premise the fix depends on and the negative half
/// it must not violate. Neither is red at the parent commit; they exist so the
/// fix cannot be silently widened or made pointless.
@Suite(.serialized)
struct GenericInstantiationContextualInitTests {
    private static let instantiation =
        "SharePreview<InterpretedTransferableValue, Never>"

    /// The premise, stated so it cannot rot silently: the table really is
    /// keyed by nominal, so resolving the instantiation REQUIRES widening.
    /// If a later change registers the full spelling, this suite is measuring
    /// something that no longer exists and should be revisited.
    @MainActor
    @Test func theConstructorTableIsKeyedByNominal() {
        #expect(GeneratedConstructors.table[Self.instantiation] == nil)
        #expect(GeneratedConstructors.table["SharePreview"] != nil)
    }

    /// The negative half: widening the LOOKUP must not widen what the
    /// parameter ACCEPTS. A `SharePreview<…, Never>` value is not admissible
    /// where the other instantiation is required — otherwise the generated
    /// overload's `as!` would trap instead of the next overload being tried.
    @MainActor
    @Test func theInstantiationStillGovernsWhatIsAccepted() throws {
        let interpreter = Interpreter()
        let payload = try InterpretedTransferableValue(
            .native(URL(string: "https://e.com/a.jpg")!),
            context: interpreter)
        let iconLess: SharePreview<InterpretedTransferableValue, Never> =
            SharePreview("share-title", image: payload)

        #expect(throws: (any Error).self) {
            _ = try GeneratedDispatch.coerce(
                .nativeSwiftUIValue(
                    "SharePreview<InterpretedTransferableValue, "
                        + "InterpretedTransferableValue>"),
                .native(iconLess),
                interpreter,
                contextualType: "SharePreview<InterpretedTransferableValue, "
                    + "InterpretedTransferableValue>")
        }
    }
}
