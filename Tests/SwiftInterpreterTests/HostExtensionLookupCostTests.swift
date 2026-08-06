import Testing
@testable import SwiftInterpreter

/// Every member access against a host payload asked
/// `hostExtensionMethodOverloads` whether a source extension supplies an
/// overload family, and that question derived the receiver's candidate type
/// names BEFORE consulting the method name. Deriving them for an array reads
/// every element to decide whether the array is homogeneous, so `a.append(x)`
/// in a loop is quadratic in the array's own size — the cost lands on
/// `Array` members no source extension has ever declared.
///
/// The pins below assert the STRUCTURE (the walk does not run) rather than a
/// duration, so they cannot go red from machine load. Interpreting
/// SwiftSoup's HTML pipeline once per status is what surfaced this.
///
/// Only the array receiver is pinned: a `String` receiver is answered before
/// this path and measured identical with and without the guard, so a pin on
/// it would be green in both directions.
@Suite("Host extension lookup cost")
struct HostExtensionLookupCostTests {
    /// The class itself: growing and reading an array must not consult the
    /// candidate type-name walk even once, because no source extension in
    /// this program declares `append`, `count`, or `sorted`.
    @Test func ordinaryArrayMembersNeverDeriveCandidateTypeNames() throws {
        let interpreter = Interpreter()
        let result = try interpreter.run(source: """
        var values: [Int] = []
        for i in 0..<200 {
            values.append((i * 7919) % 1000)
        }
        let ordered = values.sorted()
        ordered[0] + ordered[values.count - 1]
        """)

        // Native-verified: `swiftc -O` on this same snippet prints 987.
        #expect(result.intValue == 987)
        #expect(interpreter.hostExtensionCandidateDerivationCount == 0)
    }

    /// The control, and the reason the guard is a name-set membership test
    /// rather than a removal: a name a source extension DOES declare must
    /// still reach the walk and still win overload selection.
    @Test func sourceDeclaredHostExtensionStillResolves() throws {
        let interpreter = Interpreter()
        let result = try interpreter.run(source: """
        extension Array {
            func secondCount() -> Int { count * 2 }
        }
        var values: [Int] = []
        for i in 0..<8 {
            values.append(i)
        }
        values.secondCount()
        """)

        #expect(result.intValue == 16)
        #expect(interpreter.hostExtensionCandidateDerivationCount > 0)
    }
}
