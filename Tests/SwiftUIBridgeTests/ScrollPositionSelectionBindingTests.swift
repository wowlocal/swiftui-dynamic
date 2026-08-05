import SwiftUI
import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// `scrollPosition(id:)` declares `Binding<(some Hashable)?>` — an opaque
/// parameter written IN PLACE inside a compound type. BridgeGen specialized a
/// bare `some P` and a NAMED generic inside a compound type, but not this
/// third spelling, so the modifier was never generated at all.
///
/// Measured from BridgeGen's own `BRIDGEGEN_DUMP_BLOCKED` report, which is the
/// instrument this class is RED under: at `8a4a1698` it carries
/// `blocked[Binding<(some Hashable)?>] modifier scrollPosition`, and that was
/// the last open blocker on the IceCubes media browser
/// (`MediaUIView.swift:44`, `.scrollPosition(id: $scrolledItem)`), whose chain
/// reported `'.scrollPosition.toolbar.onAppear' absorbed a rendered view`.
///
/// The absorption itself is deliberately NOT asserted here. This suite's
/// harness never reaches that path — a deliberately invented modifier
/// (`.totallyUnknownModifier(7)`) on the same receiver records no diagnostic
/// either — so an absorption expectation would pass whether or not the
/// modifier is registered, which pins nothing. The behavioural half is
/// measured on the real target by the R2 board, which the close gate enforces.
@Suite(.serialized)
struct ScrollPositionSelectionBindingTests {
    /// Both overloads the interface declares reach the shared carrier — the
    /// one-argument form and the one that also takes `anchor:`. IceCubes uses
    /// both spellings across its three call sites.
    @MainActor
    @Test func bothOverloadsCarryTheSelectionBinding() {
        let single = GeneratedModifiers.table["scrollPosition"]?.byArity[1]?
            .first
        #expect(single != nil, "scrollPosition(id:) is generatable")
        #expect(single?.params.first?.tag == .bindingHashableOptional)

        let anchored = GeneratedModifiers.table["scrollPosition"]?.byArity[2]?
            .first
        #expect(anchored != nil, "scrollPosition(id:anchor:) is generatable")
        #expect(anchored?.params.first?.tag == .bindingHashableOptional)
        #expect(anchored?.params.last?.tag == .unitPoint)
    }

    /// The tag has to reach the carrier that actually round-trips, or the
    /// modifier would be registered and still lose every selection the
    /// framework writes back. Asserted through `GeneratedDispatch.coerce`,
    /// the same entry point the generated overload calls.
    @MainActor
    @Test func theTagCoercesToABindingThatRoundTrips() throws {
        let interpreter = Interpreter()
        let box = Box(RuntimeValue.nilValue)
        let coerced = try GeneratedDispatch.coerce(
            .bindingHashableOptional,
            .native(BindingStub(box: box)),
            interpreter)
        let binding = try #require(
            coerced as? Binding<InterpretedHashableValue?>)

        // Nothing selected reads as nil, not as a carrier wrapping nil.
        #expect(binding.wrappedValue == nil)

        // A framework-side write reaches the interpreted storage...
        binding.wrappedValue = InterpretedHashableValue(
            runtimeValue: .string("ROW B"))
        #expect(box.value.stringValue == "ROW B")

        // ...and an interpreted-side write reads back through the carrier.
        box.value = .string("ROW C")
        #expect(binding.wrappedValue?.runtimeValue.stringValue == "ROW C")

        // Clearing the selection is nil on both sides, which is the state the
        // modifier spends most of its life in.
        binding.wrappedValue = nil
        #expect(box.value.isNil)
        #expect(binding.wrappedValue == nil)
    }

    /// The negative control, so the specialization cannot quietly widen into a
    /// type it has no carrier for. `Plottable` has no concrete carrier, so
    /// `chartScrollPosition(x: Binding<some Plottable>)` must stay blocked
    /// rather than be emitted against a stand-in that would not compile.
    @MainActor
    @Test func aConstraintWithNoCarrierStaysUngenerated() {
        #expect(GeneratedModifiers.table["chartScrollPosition"] == nil)
    }
}
