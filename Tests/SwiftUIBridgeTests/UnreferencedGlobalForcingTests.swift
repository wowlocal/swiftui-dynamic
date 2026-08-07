import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// A host reading a top-level global BY NAME must get the same value the
/// PROGRAM would read there.
///
/// Swift globals are lazy and this interpreter models that: a top-level
/// binding holds an unforced `LazyGlobal` until something reads it. Source
/// references force it in passing, so whether a raw `globals.lookup(_:)`
/// returns a number or a thunk depends on whether some UNRELATED part of the
/// program happens to mention the same name — which is exactly the shape that
/// made this a board red rather than an obvious bug.
///
/// The IceCubes R2 capture writes both of its frozen-clock readings into
/// `CaptureMetadata` from the interpreted program's globals. One of them,
/// `__iceInterpretedClockEpoch`, is also drawn into an `.accessibilityLabel`,
/// so the render forced it and it read back fine. Its sibling
/// `__iceInterpretedRelativeClockDrift` is referenced nowhere, stayed a thunk,
/// and failed `.doubleValue` — reported as "interpreted capture clock did not
/// materialize", killing every interpreted capture on the board.
///
/// These run with `lazyTopLevelGlobals: true`, which is the mode every real
/// app harness uses (FoodTruckCheck, ProjectCheck, IceCubesCheck) and the only
/// mode in which the defect exists: script-style execution runs top-level
/// bindings in order and forces them on the way past, so the same program
/// under the default mode hides this completely.
@Suite struct UnreferencedGlobalForcingTests {
    /// The defect itself, in the two-global shape that produced it: same
    /// declaration form, same initializer kind, differing ONLY in whether a
    /// later declaration mentions the name.
    ///
    /// Measured against the raw `globals.lookup(_:)` this replaces, BOTH read
    /// nil here — nothing in this program ever calls `use()`, so neither
    /// global is forced. That is the point rather than a weaker repro: what a
    /// raw lookup returns is decided by whether unrelated code happened to RUN
    /// and touch the name, so on the real board the epoch (drawn into an
    /// `.accessibilityLabel` that the render actually evaluates) came back a
    /// number while its sibling did not.
    @Test func unreferencedGlobalReadsAsItsValueNotAThunk() throws {
        let source = """
        let referenced = 40 + 2
        let unreferenced = 40 + 3
        func use() -> Int { referenced }
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(source: source, lazyTopLevelGlobals: true)

        #expect(try interpreter.globalValue(named: "referenced")?.intValue == 42)
        #expect(try interpreter.globalValue(named: "unreferenced")?.intValue == 43)
    }

    /// The counter-direction pin: the accessor must not INVENT a global. A
    /// name that was never declared is nil, not a defaulted zero — otherwise
    /// the capture guard would read a typo as a successful zero drift, which
    /// is the one value it treats as proof the clock is frozen.
    @Test func absentGlobalIsNilRatherThanADefault() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(source: "let present = 1", lazyTopLevelGlobals: true)

        #expect(try interpreter.globalValue(named: "present")?.intValue == 1)
        #expect(try interpreter.globalValue(named: "nosuchglobal") == nil)
    }

    /// The board's own shape, distilled to the two lines the generated program
    /// actually emits: two `Date`-derived globals where only the first is
    /// mentioned again. `timeIntervalSinceNow` is the reading the R2 board
    /// requires to be exactly 0 under a frozen clock, and it is the one no
    /// view references.
    @Test func bothFrozenClockReadingsSurviveTheHostBoundary() throws {
        let source = """
        let epoch = Date().timeIntervalSince1970
        let drift = Date().timeIntervalSinceNow
        func use() -> Double { epoch }
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(source: source, lazyTopLevelGlobals: true)

        let epoch = try interpreter.globalValue(named: "epoch")?.doubleValue
        let drift = try interpreter.globalValue(named: "drift")?.doubleValue
        #expect(epoch != nil)
        // Not pinned to a value: without the harness's dyld interposer this
        // reads the real clock. What is being pinned is that it is a NUMBER
        // and not a `LazyGlobal`, which is the defect.
        #expect(drift != nil)
    }

    /// A global computed `var` re-evaluates on every read rather than
    /// memoizing, so routing host reads through the forcing path must not
    /// quietly freeze one. Guards the accessor against being "fixed" later by
    /// caching the first value it sees.
    @Test func computedGlobalStillReevaluatesPerRead() throws {
        let source = """
        var counter = 0
        var next: Int { counter += 1; return counter }
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(source: source, lazyTopLevelGlobals: true)

        #expect(try interpreter.globalValue(named: "next")?.intValue == 1)
        #expect(try interpreter.globalValue(named: "next")?.intValue == 2)
    }
}
