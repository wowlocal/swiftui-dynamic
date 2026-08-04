import SwiftUI
import Testing

@testable import SwiftUIBridge

/// An interface generic constrained only to `Hashable` had no carrier, while
/// the same generic constrained to `Equatable` — the protocol `Hashable`
/// refines — has had one since `1d82bb4f`. So a declaration asking for the
/// STRONGER guarantee got less support than one asking for the weaker.
///
/// Measured from BridgeGen's own BRIDGEGEN_DUMP_BLOCKED report: `<Hashable>`
/// was the largest single protocol blocker at 18 overloads, plus 4 more
/// spelled `some Hashable`, all of them `.matchedTransitionSource`.
@Suite(.serialized)
struct HashableCarrierTests {
    /// Both spellings of the same constraint resolve through one carrier: the
    /// opaque parameter (`some Hashable`) and the named generic (`<ID>` with
    /// `ID : Hashable`) reach the same mapping, which is why one addition
    /// answers both buckets.
    @MainActor
    @Test func bothSpellingsOfTheConstraintCarry() {
        let matchedTransitionSource = GeneratedModifiers
            .table["matchedTransitionSource"]?.byArity[2]?.first
        #expect(matchedTransitionSource != nil,
                "matchedTransitionSource(id: some Hashable, in:) is generatable")
        #expect(matchedTransitionSource?.params.first?.tag == .hashable)
        #expect(matchedTransitionSource?.params.last?.tag
                    == .nativeSwiftUIValue("Namespace.ID"))

        let matchedGeometryEffect = GeneratedModifiers
            .table["matchedGeometryEffect"]?.byArity[2]?.first
        #expect(matchedGeometryEffect?.params.first?.tag == .hashable,
                "the named-generic spelling reaches the same carrier")
    }

    /// The carrier must behave like the protocol it stands in for, or a
    /// framework collection keyed by it silently loses entries. Equal payloads
    /// are equal AND hash equal; unequal ones are unequal.
    @MainActor
    @Test func theCarrierIsConsistentWithItsOwnEquality() {
        let first = InterpretedHashableValue(runtimeValue: .native("media-1"))
        let same = InterpretedHashableValue(runtimeValue: .native("media-1"))
        let other = InterpretedHashableValue(runtimeValue: .native("media-2"))
        #expect(first == same)
        #expect(first != other)
        #expect(first.hashValue == same.hashValue)
        // Round-trips through a Set the way a framework identity slot uses it.
        var seen: Set<InterpretedHashableValue> = []
        seen.insert(first)
        seen.insert(same)
        seen.insert(other)
        #expect(seen.count == 2)
        #expect(seen.contains(same))
    }
}
